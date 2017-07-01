pragma solidity ^0.4.11;

import './ethereum-api/oraclizeAPI.sol';
import './helpers.sol';

contract Bet is usingOraclize {
  enum BET_STATES {
    OPEN,
    TEAM_ONE_WON,
    TEAM_TWO_WON,
    DRAW,
    ORACLE_UNDECIDED
    }
  
  BET_STATES bet_state = BET_STATES.OPEN;
  address public resolver;
  bool public is_featured;
  string public title;
  string public description;
  string public category;
  string public team_0; // Team 0 identifier
  string public team_1; // Team 1 identifier
  uint public team_0_bet_sum;
  uint public team_1_bet_sum;
  mapping (address => uint) public bets_to_team_0;
  mapping (address => uint) public bets_to_team_1;

  uint public timestamp_match_begin;
  uint public timestamp_match_end;
  uint public timestamp_hard_deadline; // Hard deadline to end bet
  uint public timestamp_terminate_deadline; // Self-destruct deadline > hard_deadline (this must be big, so people can withdraw their funds)

  uint constant TAX = 10; // %

  string url_oraclize;

  event new_betting(bool for_team, address from, uint amount);
  event new_winner_declared(BET_STATES winner);

  function Bet(address _resolver, string _title, string _category, 
               string _team_0, string _team_1, uint _timestamp_match_begin,
               uint _timestamp_match_end, uint _timestamp_hard_deadline,
               uint _timestamp_terminate_deadline, string _url_oraclize) {
    resolver = _resolver;
    title = _title;
    category = _category;
    team_0 = _team_0;
    team_1 = _team_1;
    timestamp_match_begin = _timestamp_match_begin;
    timestamp_match_end = _timestamp_match_end;
    timestamp_terminate_deadline = _timestamp_terminate_deadline;
    url_oraclize = _url_oraclize;
  }

  function arbitrate(BET_STATES result) {
    require(block.timestamp >= timestamp_hard_deadline);
    require(bet_state == BET_STATES.ORACLE_UNDECIDED);
    require(result != BET_STATES.ORACLE_UNDECIDED);
    require(result != BET_STATES.OPEN);
    
    bet_state = result;
    new_winner_declared(result);
  }

  function __callback(bytes32 myid, string result) {
    // Cannot call after hard deadline
    require(block.timestamp < timestamp_hard_deadline);
    // Oraclize should call this
    require(msg.sender == oraclize_cbAddress());
    // Must be called after the bet ends
    require(block.timestamp >= timestamp_match_end);

    if (Helpers.string_equal(result, team_0))
      bet_state = BET_STATES.TEAM_ONE_WON;
    else if (Helpers.string_equal(result, team_1))
      bet_state = BET_STATES.TEAM_TWO_WON;
    else
      bet_state = BET_STATES.ORACLE_UNDECIDED;

    new_winner_declared(bet_state);
  }

  function update_result() payable {
    // Can call only when bet is open or undecided
    require(bet_state == BET_STATES.OPEN || bet_state == BET_STATES.ORACLE_UNDECIDED);
    require(block.timestamp >= timestamp_match_end);

    oraclize_query('URL', url_oraclize);
  }
  
  function toggle_featured() {
    require(msg.sender == resolver);

    is_featured = !is_featured;
  }
  
  // 
  function bet(bool for_team) payable {
    require(block.timestamp < timestamp_match_begin);
    uint prev_sum;
    
    if (for_team) {
      // Cannot bet in two teams
      require(bets_to_team_1[msg.sender] == 0);
      prev_sum = team_0_bet_sum;
      team_0_bet_sum += msg.value;
      assert(team_0_bet_sum >= prev_sum);
      bets_to_team_0[msg.sender] += msg.value;
    }
    else {
      // Cannot bet in two teams
      require(bets_to_team_0[msg.sender] == 0);
      prev_sum = team_1_bet_sum;
      team_1_bet_sum += msg.value;
      assert(team_1_bet_sum >= prev_sum);
      bets_to_team_1[msg.sender] += msg.value;
    }

    new_betting(for_team, msg.sender, msg.value);
  }

  function withdraw() {
    require(block.timestamp < timestamp_match_begin || bet_state == BET_STATES.TEAM_ONE_WON || bet_state == BET_STATES.TEAM_TWO_WON || bet_state == BET_STATES.DRAW);
    if (block.timestamp < timestamp_match_begin || bet_state == BET_STATES.DRAW) {
        collect_bet();
    }
    else {
        collect_profit();
    }
  }

  // Transfers the user's initial bet back
  function collect_bet() internal {
    require(bets_to_team_0[msg.sender] > 0 || bets_to_team_1[msg.sender] > 0);

    if (bets_to_team_0[msg.sender] > 0) {
      msg.sender.transfer(bets_to_team_0[msg.sender]);
      bets_to_team_0[msg.sender] = 0;
    }
    else { // if (bets_to_team_1[msg.sender] > 0)
      msg.sender.transfer(bets_to_team_1[msg.sender]);
      bets_to_team_1[msg.sender] = 0;
    }
  }

  // Transfers the user's profit
  function collect_profit() internal {
    require( ( bet_state == BET_STATES.TEAM_ONE_WON && bets_to_team_0[msg.sender] > 0 ) || ( bet_state == BET_STATES.TEAM_TWO_WON && bets_to_team_1[msg.sender] > 0 ) );

    uint bet = 0;
    uint sum = 0;
    uint profit = 0;

    if (bet_state == BET_STATES.TEAM_ONE_WON && bets_to_team_0[msg.sender] > 0) {
      bet = bets_to_team_0[msg.sender];
      sum = team_0_bet_sum;
      profit = team_1_bet_sum;
    }
    else { // if (BET_STATES.bet_state == TEAM_TWO_WON && bets_to_team_1[msg.sender] > 0)
      bet = bets_to_team_1[msg.sender];
      sum = team_1_bet_sum;
      profit = team_1_bet_sum;
    }

    assert(bet <= sum);

    // Approach one:
    // We might lose precision, but no overflow
    uint sender_pc = bet / sum; // THIS SHOULD BE FLOAT
    uint sender_profit = sender_pc * profit; // THIS SHOULD BE FLOAT
    // Approach two:
    // Better precision, since multiplication is done first, but may overflow
    //uint sender_profit = (bet * profit) / sum; // THIS SHOULD BE FLOAT

    assert(sender_pc <= 1);
    assert(sender_profit <= profit);

    uint tax = (sender_profit * TAX) / 100;
    assert(tax <= sender_profit);

    uint notax_profit = sender_profit;
    sender_profit -= tax;
    assert(sender_profit <= notax_profit);

    resolver.transfer(tax);
    msg.sender.transfer(sender_profit);
    
    collect_bet();
  }
  
  // If the oracle fails or is not able to get the right answer
  function resolve_conflict(uint8 for_team_idx) {
    require(msg.sender == resolver);

  }
}
