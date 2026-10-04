// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IVRFHandler } from "src/IVRFHandler.sol";
import { VRFHandler } from "src/VRFHandler.sol";
import { VRFHandlerTest } from "test/VRFHandler.t.sol";

/// @title Tests for immutable execution-scoped randomness requests
contract VRFHandlerTest_Execution is VRFHandlerTest {
  bytes32 internal constant COMMITMENT_HASH = keccak256("execution-commitment");
  bytes32 internal constant EXECUTION_ID = keccak256("globally-unique-execution");
  uint32 internal constant FINALITY_BLOCKS = 5;
  uint32 internal constant WORD_COUNT = 3;

  function test_computeExecutionKey_matchesCanonicalEncoding() public view {
    bytes32 expected = keccak256(
      abi.encodePacked(
        "chainlink-vrf-service-execution-v1", bytes1(0), block.chainid, address(vrfHandler), EXECUTION_ID
      )
    );

    assertEq(vrfHandler.computeExecutionKey(EXECUTION_ID), expected);
  }

  function test_requestRandomWordsForExecution_storesImmutableInputs() public {
    uint64 terminalAt = _futureTerminalAt();
    (uint256 requestId, bytes32 executionKey) = _requestExecution(terminalAt);

    IVRFHandler.Execution memory execution = vrfHandler.getExecution(executionKey);
    assertEq(execution.executionId, EXECUTION_ID);
    assertEq(execution.commitmentHash, COMMITMENT_HASH);
    assertEq(execution.randomWordsHash, bytes32(0));
    assertEq(execution.requestId, requestId);
    assertEq(execution.requestedAtBlock, block.number);
    assertEq(execution.fulfilledAtBlock, 0);
    assertEq(execution.requester, address(receiver));
    assertEq(execution.requestedAt, block.timestamp);
    assertEq(execution.terminalAt, terminalAt);
    assertEq(execution.randomWordsAmount, WORD_COUNT);
    assertEq(execution.finalityBlocks, FINALITY_BLOCKS);
    assertEq(uint8(execution.status), uint8(IVRFHandler.ExecutionStatus.Requested));
    assertEq(vrfHandler.vrfRequestIdToExecutionKey(requestId), executionKey);
    assertEq(vrfHandler.vrfRequestIdToRequester(requestId), address(receiver));
    assertEq(vrfHandler.activeRequests(), 1);
  }

  function test_requestRandomWordsForExecution_emitsCanonicalEvidence() public {
    uint64 terminalAt = _futureTerminalAt();
    bytes32 executionKey = vrfHandler.computeExecutionKey(EXECUTION_ID);

    vm.expectEmit(true, true, false, true);
    emit VRFHandler.RandomWordsRequested(1, address(receiver), WORD_COUNT);
    vm.expectEmit(true, true, true, true);
    emit VRFHandler.ExecutionRequested(
      executionKey, 1, address(receiver), EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, terminalAt, FINALITY_BLOCKS
    );

    vm.prank(address(receiver));
    vrfHandler.requestRandomWordsForExecution(EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, terminalAt, FINALITY_BLOCKS);
  }

  function test_requestRandomWordsForExecution_rejectsDuplicateAcrossRequesters() public {
    (, bytes32 executionKey) = _requestExecution(_futureTerminalAt());

    vm.prank(deployer);
    vrfHandler.addAllowedRequester(requester);

    vm.prank(requester);
    vm.expectRevert(abi.encodeWithSelector(VRFHandler.ExecutionAlreadyRegistered.selector, executionKey));
    vrfHandler.requestRandomWordsForExecution(
      EXECUTION_ID, keccak256("changed-commitment"), WORD_COUNT, _futureTerminalAt(), FINALITY_BLOCKS
    );
  }

  function test_requestRandomWordsForExecution_rejectsInvalidInputs() public {
    uint64 terminalAt = _futureTerminalAt();

    vm.startPrank(address(receiver));

    vm.expectRevert(VRFHandler.InvalidParameter.selector);
    vrfHandler.requestRandomWordsForExecution(bytes32(0), COMMITMENT_HASH, WORD_COUNT, terminalAt, FINALITY_BLOCKS);

    vm.expectRevert(VRFHandler.InvalidParameter.selector);
    vrfHandler.requestRandomWordsForExecution(EXECUTION_ID, bytes32(0), WORD_COUNT, terminalAt, FINALITY_BLOCKS);

    vm.expectRevert(VRFHandler.InvalidParameter.selector);
    vrfHandler.requestRandomWordsForExecution(EXECUTION_ID, COMMITMENT_HASH, 0, terminalAt, FINALITY_BLOCKS);

    vm.expectRevert(VRFHandler.InvalidParameter.selector);
    vrfHandler.requestRandomWordsForExecution(EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, terminalAt, 0);

    vm.expectRevert(VRFHandler.InvalidParameter.selector);
    vrfHandler.requestRandomWordsForExecution(
      EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, uint64(block.timestamp), FINALITY_BLOCKS
    );

    vm.stopPrank();
  }

  function test_requestRandomWordsForExecution_rejectsUnauthorizedRequester() public {
    vm.prank(randomUser);
    vm.expectRevert(VRFHandler.Unauthorized.selector);
    vrfHandler.requestRandomWordsForExecution(
      EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, _futureTerminalAt(), FINALITY_BLOCKS
    );
  }

  function test_fulfillExecution_recordsWordsAndRequiresFinality() public {
    (uint256 requestId, bytes32 executionKey) = _requestExecution(_futureTerminalAt());
    uint256[] memory randomWords = _generateRandomWords(WORD_COUNT);

    vm.roll(block.number + 2);
    uint256 fulfilledAtBlock = block.number;
    bytes32 randomWordsHash = keccak256(abi.encode(randomWords));

    vm.expectEmit(true, true, true, true);
    emit VRFHandler.ExecutionFulfilled(executionKey, requestId, COMMITMENT_HASH, randomWordsHash);
    vm.prank(address(coordinator));
    vrfHandler.rawFulfillRandomWords(requestId, randomWords);

    IVRFHandler.Execution memory execution = vrfHandler.getExecution(executionKey);
    assertEq(execution.randomWordsHash, randomWordsHash);
    assertEq(execution.fulfilledAtBlock, fulfilledAtBlock);
    assertEq(uint8(execution.status), uint8(IVRFHandler.ExecutionStatus.Fulfilled));
    assertFalse(vrfHandler.isExecutionUsable(executionKey));
    assertFalse(receiver.randomWordsFulfilled());

    vm.roll(fulfilledAtBlock + FINALITY_BLOCKS - 1);
    assertFalse(vrfHandler.isExecutionUsable(executionKey));

    vm.roll(fulfilledAtBlock + FINALITY_BLOCKS);
    assertTrue(vrfHandler.isExecutionUsable(executionKey));
  }

  function test_cancelExecution_isTerminalAndIgnoresLaterFulfillment() public {
    (uint256 requestId, bytes32 executionKey) = _requestExecution(_futureTerminalAt());

    vm.expectEmit(true, true, true, true);
    emit VRFHandler.ExecutionCancelled(executionKey, requestId, address(receiver));
    vm.prank(address(receiver));
    vrfHandler.cancelExecution(EXECUTION_ID);

    uint256[] memory randomWords = _generateRandomWords(WORD_COUNT);
    vm.expectEmit(true, true, true, true);
    emit VRFHandler.ExecutionFulfillmentIgnored(executionKey, requestId, IVRFHandler.ExecutionStatus.Cancelled);
    vm.prank(address(coordinator));
    vrfHandler.rawFulfillRandomWords(requestId, randomWords);

    IVRFHandler.Execution memory execution = vrfHandler.getExecution(executionKey);
    assertEq(uint8(execution.status), uint8(IVRFHandler.ExecutionStatus.Cancelled));
    assertEq(execution.randomWordsHash, bytes32(0));
    assertFalse(vrfHandler.isExecutionUsable(executionKey));
    assertEq(vrfHandler.activeRequests(), 0);

    vm.prank(address(receiver));
    vm.expectRevert(abi.encodeWithSelector(VRFHandler.ExecutionAlreadyRegistered.selector, executionKey));
    vrfHandler.requestRandomWordsForExecution(
      EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, _futureTerminalAt(), FINALITY_BLOCKS
    );
  }

  function test_cancelExecution_rejectsDifferentRequester() public {
    _requestExecution(_futureTerminalAt());

    vm.prank(randomUser);
    vm.expectRevert(VRFHandler.Unauthorized.selector);
    vrfHandler.cancelExecution(EXECUTION_ID);
  }

  function test_expireExecution_isPermissionlessAtTerminalTime() public {
    uint64 terminalAt = _futureTerminalAt();
    (uint256 requestId, bytes32 executionKey) = _requestExecution(terminalAt);

    vm.prank(randomUser);
    vm.expectRevert(abi.encodeWithSelector(VRFHandler.ExecutionNotExpired.selector, executionKey, terminalAt));
    vrfHandler.expireExecution(executionKey);

    vm.warp(terminalAt);
    vm.expectEmit(true, true, false, true);
    emit VRFHandler.ExecutionExpired(executionKey, requestId);
    vm.prank(randomUser);
    vrfHandler.expireExecution(executionKey);

    IVRFHandler.Execution memory execution = vrfHandler.getExecution(executionKey);
    assertEq(uint8(execution.status), uint8(IVRFHandler.ExecutionStatus.Expired));
    assertFalse(vrfHandler.isExecutionUsable(executionKey));
  }

  function test_lateFulfillment_expiresAndCannotBecomeUsable() public {
    uint64 terminalAt = _futureTerminalAt();
    (uint256 requestId, bytes32 executionKey) = _requestExecution(terminalAt);
    uint256[] memory randomWords = _generateRandomWords(WORD_COUNT);

    vm.warp(terminalAt);
    vm.prank(address(coordinator));
    vrfHandler.rawFulfillRandomWords(requestId, randomWords);

    IVRFHandler.Execution memory execution = vrfHandler.getExecution(executionKey);
    assertEq(uint8(execution.status), uint8(IVRFHandler.ExecutionStatus.Expired));
    assertEq(execution.randomWordsHash, bytes32(0));
    assertFalse(vrfHandler.isExecutionUsable(executionKey));
    assertTrue(vrfHandler.vrfFulfilledRequests(requestId));
    assertEq(vrfHandler.activeRequests(), 0);
  }

  function test_terminalStatesRejectCancellation() public {
    (uint256 requestId, bytes32 executionKey) = _requestExecution(_futureTerminalAt());
    uint256[] memory randomWords = _generateRandomWords(WORD_COUNT);

    vm.prank(address(coordinator));
    vrfHandler.rawFulfillRandomWords(requestId, randomWords);

    vm.prank(address(receiver));
    vm.expectRevert(
      abi.encodeWithSelector(
        VRFHandler.ExecutionNotPending.selector, executionKey, IVRFHandler.ExecutionStatus.Fulfilled
      )
    );
    vrfHandler.cancelExecution(EXECUTION_ID);
  }

  function _futureTerminalAt() internal view returns (uint64) {
    return uint64(block.timestamp + 1 hours);
  }

  function _requestExecution(uint64 terminalAt) internal returns (uint256 requestId, bytes32 executionKey) {
    vm.prank(address(receiver));
    return
      vrfHandler.requestRandomWordsForExecution(EXECUTION_ID, COMMITMENT_HASH, WORD_COUNT, terminalAt, FINALITY_BLOCKS);
  }
}
