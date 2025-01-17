// SPDX-License-Identifier: GPL-3.0-or-later
/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity 0.8.23;
pragma experimental ABIEncoderV2;

import { VotingReputationStorage } from "./VotingReputationStorage.sol";
import { IColony, ColonyDataTypes } from "./../../colony/IColony.sol";

contract VotingReputation is VotingReputationStorage {
  // Public

  function initialise(
    uint256 _totalStakeFraction,
    uint256 _voterRewardFraction,
    uint256 _userMinStakeFraction,
    uint256 _maxVoteFraction,
    uint256 _stakePeriod,
    uint256 _submitPeriod,
    uint256 _revealPeriod,
    uint256 _escalationPeriod
  ) public onlyRoot {
    require(state == ExtensionState.Deployed, "voting-rep-already-initialised");

    require(_totalStakeFraction <= WAD / 2, "voting-rep-greater-than-half-wad");
    require(_voterRewardFraction <= WAD / 2, "voting-rep-greater-than-half-wad");

    require(_userMinStakeFraction <= WAD, "voting-rep-greater-than-wad");
    require(_maxVoteFraction <= WAD, "voting-rep-greater-than-wad");

    require(_stakePeriod <= 365 days, "voting-rep-period-too-long");
    require(_submitPeriod <= 365 days, "voting-rep-period-too-long");
    require(_revealPeriod <= 365 days, "voting-rep-period-too-long");
    require(_escalationPeriod <= 365 days, "voting-rep-period-too-long");

    state = ExtensionState.Active;

    totalStakeFraction = _totalStakeFraction;
    voterRewardFraction = _voterRewardFraction;

    userMinStakeFraction = _userMinStakeFraction;
    maxVoteFraction = _maxVoteFraction;

    stakePeriod = _stakePeriod;
    submitPeriod = _submitPeriod;
    revealPeriod = _revealPeriod;
    escalationPeriod = _escalationPeriod;

    emit ExtensionInitialised();
  }

  function createMotion(
    uint256 _domainId,
    uint256 _childSkillIndex,
    address _altTarget,
    bytes memory _action,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  ) public notDeprecated {
    require(state == ExtensionState.Active, "voting-rep-not-active");
    require(_altTarget != address(colony), "voting-rep-alt-target-cannot-be-base-colony");

    ActionSummary memory actionSummary = getActionSummary(_action, _altTarget);

    require(actionSummary.sig != OLD_MOVE_FUNDS, "voting-rep-disallowed-function");
    require(
      actionSummary.domainSkillId != type(uint256).max &&
        actionSummary.expenditureId != type(uint256).max,
      "voting-rep-invalid-multicall"
    );

    uint256 domainSkillId = colony.getDomain(_domainId).skillId;

    if (actionSummary.sig == NO_ACTION) {
      // For the special no-op action, we hold the vote the provided domain
      require(_childSkillIndex == UINT256_MAX, "voting-rep-invalid-domain-id");
      actionSummary.domainSkillId = domainSkillId;
    } else {
      // Otherwise, we validate the vote domain against the action
      if (domainSkillId == actionSummary.domainSkillId) {
        require(_childSkillIndex == UINT256_MAX, "voting-rep-invalid-domain-id");
      } else {
        uint256 childSkillId = colonyNetwork.getChildSkillId(domainSkillId, _childSkillIndex);
        require(childSkillId == actionSummary.domainSkillId, "voting-rep-invalid-domain-id");
      }
    }

    motionCount += 1;
    Motion storage motion = motions[motionCount];
    motion.events[STAKE_END] = uint64(block.timestamp + stakePeriod);

    motion.rootHash = colonyNetwork.getReputationRootHash();
    motion.domainId = _domainId;
    motion.skillId = domainSkillId;

    motion.skillRep = checkReputation(
      motion.rootHash,
      domainSkillId,
      address(0x0),
      _key,
      _value,
      _branchMask,
      _siblings
    );
    require(motion.skillRep > 0, "voting-rep-no-reputation-in-domain");
    motion.altTarget = _altTarget;
    motion.action = _action;
    motion.sig = actionSummary.sig;

    // If an expenditure motion, make sure no v9 motions are holding a lock
    if (isExpenditureSig(actionSummary.sig)) {
      bytes32 structHash1 = getExpenditureStructHash(getExpenditureAction(motion.action));
      require(expenditureMotionCounts_DEPRECATED[structHash1] == 0, "voting-rep-motion-locked");
      // Check the main expenditure as well, in case the action is a slot action
      uint256 expenditureId = getExpenditureId(getExpenditureAction(motion.action));
      bytes32 structHash2 = keccak256(abi.encodePacked(expenditureId));
      require(expenditureMotionCounts_DEPRECATED[structHash2] == 0, "voting-rep-motion-locked");
      // There may be existing v9 slot motions, we can't really check that...
      //  On the plus side, new motions can't be slot motions so there's no possibility of interference
    }

    emit MotionCreated(motionCount, msgSender(), _domainId);
  }

  function submitVote(
    uint256 _motionId,
    bytes32 _voteSecret,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  ) public {
    Motion storage motion = motions[_motionId];
    require(getMotionState(_motionId) == MotionState.Submit, "voting-rep-motion-not-open");
    require(_voteSecret != bytes32(0), "voting-rep-invalid-secret");

    uint256 userRep = checkReputation(
      motion.rootHash,
      motion.skillId,
      msgSender(),
      _key,
      _value,
      _branchMask,
      _siblings
    );

    // Count reputation if first submission
    if (voteSecrets[_motionId][msgSender()] == bytes32(0)) {
      motion.repSubmitted += userRep;
    }

    voteSecrets[_motionId][msgSender()] = _voteSecret;

    emit MotionVoteSubmitted(_motionId, msgSender());

    if (motion.repSubmitted >= wmul(motion.skillRep, maxVoteFraction)) {
      motion.events[SUBMIT_END] = uint64(block.timestamp);
      motion.events[REVEAL_END] = uint64(block.timestamp + revealPeriod);

      emit MotionEventSet(_motionId, SUBMIT_END);
    }
  }

  function revealVote(
    uint256 _motionId,
    bytes32 _salt,
    uint256 _vote,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  ) public {
    Motion storage motion = motions[_motionId];
    require(getMotionState(_motionId) == MotionState.Reveal, "voting-rep-motion-not-reveal");
    require(_vote <= 1, "voting-rep-bad-vote");

    uint256 userRep = checkReputation(
      motion.rootHash,
      motion.skillId,
      msgSender(),
      _key,
      _value,
      _branchMask,
      _siblings
    );
    motion.votes[_vote] += userRep;

    bytes32 voteSecret = voteSecrets[_motionId][msgSender()];
    require(voteSecret == keccak256(abi.encodePacked(_salt, _vote)), "voting-rep-secret-no-match");
    delete voteSecrets[_motionId][msgSender()];

    uint256 voterReward = getVoterReward(_motionId, userRep);
    motion.paidVoterComp += voterReward;

    emit MotionVoteRevealed(_motionId, msgSender(), _vote);

    // See if reputation revealed matches reputation submitted
    if ((motion.votes[NAY] + motion.votes[YAY]) == motion.repSubmitted) {
      motion.events[REVEAL_END] = uint64(block.timestamp);

      emit MotionEventSet(_motionId, REVEAL_END);
    }

    tokenLocking.transfer(token, voterReward, msgSender(), true);
  }

  function escalateMotion(
    uint256 _motionId,
    uint256 _newDomainId,
    uint256 _childSkillIndex,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  ) public {
    Motion storage motion = motions[_motionId];
    require(getMotionState(_motionId) == MotionState.Closed, "voting-rep-motion-not-closed");

    uint256 newDomainSkillId = colony.getDomain(_newDomainId).skillId;
    uint256 childSkillId = colonyNetwork.getChildSkillId(newDomainSkillId, _childSkillIndex);
    require(childSkillId == motion.skillId, "voting-rep-invalid-domain-proof");

    uint256 domainId = motion.domainId;
    motion.domainId = _newDomainId;
    motion.skillId = newDomainSkillId;
    motion.skillRep = checkReputation(
      motion.rootHash,
      motion.skillId,
      address(0x0),
      _key,
      _value,
      _branchMask,
      _siblings
    );

    uint256 loser = (motion.votes[NAY] < motion.votes[YAY]) ? NAY : YAY;
    motion.stakes[loser] -= motion.paidVoterComp;
    motion.pastVoterComp[loser] += motion.paidVoterComp;
    delete motion.paidVoterComp;

    uint256 requiredStake = getRequiredStake(_motionId);

    if (motion.stakes[NAY] < requiredStake || motion.stakes[YAY] < requiredStake) {
      motion.events[STAKE_END] = uint64(block.timestamp + stakePeriod);
    } else {
      motion.events[STAKE_END] = uint64(block.timestamp);
      motion.events[SUBMIT_END] = motion.events[STAKE_END] + uint64(submitPeriod);
      motion.events[REVEAL_END] = motion.events[SUBMIT_END] + uint64(revealPeriod);
    }

    motion.escalated = true;

    emit MotionEscalated(_motionId, msgSender(), domainId, _newDomainId);

    if (motion.events[STAKE_END] <= uint64(block.timestamp)) {
      emit MotionEventSet(_motionId, STAKE_END);
    }
  }

  function finalizeMotion(uint256 _motionId) public {
    Motion storage motion = motions[_motionId];
    require(
      getMotionState(_motionId) == MotionState.Finalizable,
      "voting-rep-motion-not-finalizable"
    );

    assert(
      motion.stakes[YAY] == getRequiredStake(_motionId) ||
        (motion.votes[NAY] + motion.votes[YAY]) > 0
    );

    motion.finalized = true;

    bool canExecute = (motion.stakes[NAY] < motion.stakes[YAY] ||
      motion.votes[NAY] < motion.votes[YAY]);

    // Perform vote power checks
    if (_motionId > motionCountV10) {
      // New functionality for versions 10 and above
      if (isExpenditureSig(motion.sig) && getTarget(motion.altTarget) == address(colony)) {
        uint256 expenditureId = unlockExpenditure(_motionId);
        uint256 votePower = (motion.votes[NAY] + motion.votes[YAY]) > 0
          ? motion.votes[YAY]
          : motion.stakes[YAY];

        if (expenditurePastVotes[expenditureId] < votePower) {
          expenditurePastVotes[expenditureId] = votePower;
        } else if (motion.domainId > 1) {
          canExecute = false;
        }
      }
    } else {
      // Backwards compatibility for versions 9 and below
      ActionSummary memory actionSummary = getActionSummary(motion.action, motion.altTarget);
      if (isExpenditureSig(actionSummary.sig) && getTarget(motion.altTarget) == address(colony)) {
        if (getSig(motion.action) != MULTICALL) {
          unlockV9Expenditure(_motionId);
        }

        uint256 votePower = (motion.votes[NAY] + motion.votes[YAY]) > 0
          ? motion.votes[YAY]
          : motion.stakes[YAY];

        bytes memory action = getExpenditureAction(motion.action);
        bytes32 actionHash = hashExpenditureAction(action);

        if (expenditurePastVotes_DEPRECATED[actionHash] < votePower) {
          expenditurePastVotes_DEPRECATED[actionHash] = votePower;
        } else if (motion.domainId > 1) {
          canExecute = false;
        }
      }
    }

    bool executed;

    if (canExecute) {
      executed = executeCall(_motionId, motion.action);
      require(
        executed || failingExecutionAllowed(_motionId),
        "voting-execution-failed-not-one-week"
      );
    }

    emit MotionFinalized(_motionId, motion.action, executed);
  }

  function failingExecutionAllowed(uint256 _motionId) public view returns (bool _allowed) {
    Motion storage motion = motions[_motionId];
    uint256 requiredStake = getRequiredStake(_motionId);

    // Failing execution is allowed if we didn't fully stake, and it's been a week since staking ended
    if (motion.stakes[YAY] < requiredStake || motion.stakes[NAY] < requiredStake) {
      return block.timestamp >= motion.events[STAKE_END] + 7 days;
    } else {
      // It was fully staked, and went to a vote.
      // Failing execution is also allowed if it's been a week since reveal ended
      return block.timestamp >= motion.events[REVEAL_END] + 7 days;
    }
  }

  // Public view functions

  function getTotalStakeFraction() public view returns (uint256 _fraction) {
    return totalStakeFraction;
  }

  function getVoterRewardFraction() public view returns (uint256 _fraction) {
    return voterRewardFraction;
  }

  function getUserMinStakeFraction() public view returns (uint256 _fraction) {
    return userMinStakeFraction;
  }

  function getMaxVoteFraction() public view returns (uint256 _fraction) {
    return maxVoteFraction;
  }

  function getStakePeriod() public view returns (uint256 _period) {
    return stakePeriod;
  }

  function getSubmitPeriod() public view returns (uint256 _period) {
    return submitPeriod;
  }

  function getRevealPeriod() public view returns (uint256 _period) {
    return revealPeriod;
  }

  function getEscalationPeriod() public view returns (uint256 _period) {
    return escalationPeriod;
  }

  function getMotionCount() public view returns (uint256 _count) {
    return motionCount;
  }

  function getMotion(uint256 _motionId) public view returns (Motion memory _motion) {
    _motion = motions[_motionId];
  }

  function getStake(
    uint256 _motionId,
    address _staker,
    uint256 _vote
  ) public view returns (uint256 _stake) {
    return stakes[_motionId][_staker][_vote];
  }

  function getExpenditureMotionCount(bytes32 _structHash) public view returns (uint256 _count) {
    return expenditureMotionCounts_DEPRECATED[_structHash];
  }

  function getExpenditureMotionLock(
    uint256 _expenditureId
  ) public view returns (uint256 _motionId) {
    return expenditureMotionLocks[_expenditureId];
  }

  function getExpenditurePastVote(uint256 _expenditureId) public view returns (uint256 _vote) {
    return expenditurePastVotes[_expenditureId];
  }

  function getExpenditurePastVotes_DEPRECATED(
    bytes32 _slotSignature
  ) public view returns (uint256 _vote) {
    return expenditurePastVotes_DEPRECATED[_slotSignature];
  }

  function getVoterReward(
    uint256 _motionId,
    uint256 _voterRep
  ) public view returns (uint256 _reward) {
    Motion storage motion = motions[_motionId];
    uint256 fractionUserReputation = wdiv(_voterRep, motion.repSubmitted);
    uint256 totalStake = motion.stakes[YAY] + motion.stakes[NAY];
    return wmul(wmul(fractionUserReputation, totalStake), voterRewardFraction);
  }

  function getVoterRewardRange(
    uint256 _motionId,
    uint256 _voterRep,
    address _voterAddress
  ) public view returns (uint256 _rewardMin, uint256 _rewardMax) {
    Motion storage motion = motions[_motionId];
    // The minimum reward is when everyone has voted, with a total weight of motion.skillRep
    uint256 minFractionUserReputation = wdiv(_voterRep, motion.skillRep);

    // The maximum reward is when this user is the only other person who votes (if they haven't already),
    // aside from those who have already done so
    uint256 voteTotal = motion.repSubmitted;
    // Has the user already voted?
    if (voteSecrets[_motionId][_voterAddress] == bytes32(0)) {
      // They have not, so add their rep
      voteTotal += _voterRep;
    }
    uint256 maxFractionUserReputation = wdiv(_voterRep, voteTotal);

    uint256 totalStake = motion.stakes[YAY] + motion.stakes[NAY];
    return (
      wmul(wmul(minFractionUserReputation, totalStake), voterRewardFraction),
      wmul(wmul(maxFractionUserReputation, totalStake), voterRewardFraction)
    );
  }

  // Internal

  function unlockExpenditure(uint256 _motionId) internal returns (uint256) {
    // This function is only for motions made with v10 and above
    assert(_motionId > motionCountV10);

    Motion storage motion = motions[_motionId];
    bytes memory action = getExpenditureAction(motion.action);
    uint256 expenditureId = getExpenditureId(action);

    assert(expenditureMotionLocks[expenditureId] == _motionId);
    delete expenditureMotionLocks[expenditureId];

    ColonyDataTypes.Expenditure memory expenditure = colony.getExpenditure(expenditureId);
    uint256 sinceFinalized = (expenditure.status == ColonyDataTypes.ExpenditureStatus.Finalized)
      ? (block.timestamp - expenditure.finalizedTimestamp)
      : 0;
    uint256 newClaimDelay = (expenditure.globalClaimDelay > LOCK_DELAY)
      ? expenditure.globalClaimDelay - LOCK_DELAY
      : 0;

    bytes memory claimDelayAction = createGlobalClaimDelayAction(
      action,
      newClaimDelay + sinceFinalized
    );
    // No require this time, since we don't want stakes to be permanently locked
    executeCall(_motionId, claimDelayAction);

    return expenditureId;
  }

  // This function is only for non-multicall motions created with v9 and below
  function unlockV9Expenditure(uint256 _motionId) internal returns (uint256) {
    Motion storage motion = motions[_motionId];

    assert(_motionId <= motionCountV10);
    assert(getSig(motion.action) != MULTICALL);

    bytes32 structHash = getExpenditureStructHash(motion.action);
    expenditureMotionCounts_DEPRECATED[structHash]--;

    // Release the claimDelay if this is the last active motion
    if (expenditureMotionCounts_DEPRECATED[structHash] == 0) {
      bytes memory claimDelayAction = createClaimDelayAction(motion.action, 0);
      // No require this time, since we don't want stakes to be permanently locked
      executeCall(_motionId, claimDelayAction);
    }

    return getExpenditureId(motion.action);
  }

  // NOTE: This function is deprecated and only used to support v9 expenditure motions
  function getExpenditureStructHash(
    bytes memory _action
  ) internal pure returns (bytes32 structHash) {
    bytes4 sig = getSig(_action);
    uint256 expenditureId;
    uint256 storageSlot;

    assembly {
      expenditureId := mload(add(_action, 0x64))
      storageSlot := mload(add(_action, 0x84))
    }

    if (sig == SET_EXPENDITURE_STATE && storageSlot == 25) {
      structHash = keccak256(abi.encodePacked(expenditureId));
    } else {
      uint256 expenditureSlot;
      uint256 expenditureSlotLoc = (sig == SET_EXPENDITURE_STATE) ? 0x184 : 0x84;
      assembly {
        expenditureSlot := mload(add(_action, expenditureSlotLoc))
      }
      structHash = keccak256(abi.encodePacked(expenditureId, expenditureSlot));
    }
  }

  // NOTE: This function is deprecated and only used to support v9 expenditure motions
  function hashExpenditureAction(bytes memory action) internal pure returns (bytes32 hash) {
    bytes4 sig = getSig(action);
    assert(sig == SET_EXPENDITURE_STATE || sig == SET_EXPENDITURE_PAYOUT);

    uint256 valueLoc = (sig == SET_EXPENDITURE_STATE) ? 0xe4 : 0xc4;

    // Hash all but the domain proof and action value, so actions for the
    //   same storage slot return the same hash.
    // Recall: mload(action) gives the length of the bytes array
    // So skip past the three bytes32 (length + domain proof),
    //   plus 4 bytes for the sig (0x64). Subtract the same from the end, less
    //   the length bytes32 (0x44). And zero out the value.

    assembly {
      mstore(add(action, valueLoc), 0x0)
      hash := keccak256(add(action, 0x64), sub(mload(action), 0x44))
    }
  }
}
