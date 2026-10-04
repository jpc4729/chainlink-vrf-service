// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IVRFHandler } from "src/IVRFHandler.sol";

/// @title VRFHandler Mock
/// @notice A mock implementation of the VRFHandler interface for testing
contract VRFHandlerMock is IVRFHandler {
  uint256 private _requestId = 0;
  mapping(uint256 => address) public requestIdToRequester;
  mapping(bytes32 => Execution) private _executions;
  mapping(uint256 => bytes32) private _requestIdToExecutionKey;

  function requestRandomWords(uint32 randomWordsAmount) external override returns (uint256 requestId) {
    _requestId++;
    requestIdToRequester[_requestId] = msg.sender;
    return _requestId;
  }

  function requestRandomWords(uint32 randomWordsAmount, bytes4 selector) external override returns (uint256 requestId) {
    _requestId++;
    requestIdToRequester[_requestId] = msg.sender;
    return _requestId;
  }

  function requestRandomWordsWithCommitment(
    uint32 randomWordsAmount,
    bytes32 manifestHash,
    uint256 rangeSize
  )
    external
    override
    returns (uint256 requestId)
  {
    _requestId++;
    requestIdToRequester[_requestId] = msg.sender;
    return _requestId;
  }

  function requestRandomWordsForExecution(
    bytes32 executionId,
    bytes32 commitmentHash,
    uint32 randomWordsAmount,
    uint64 terminalAt,
    uint32 finalityBlocks
  )
    external
    override
    returns (uint256 requestId, bytes32 executionKey)
  {
    executionKey = computeExecutionKey(executionId);
    require(_executions[executionKey].status == ExecutionStatus.None, "VRFHandlerMock: Execution exists");

    _requestId++;
    requestId = _requestId;
    requestIdToRequester[requestId] = msg.sender;
    _requestIdToExecutionKey[requestId] = executionKey;
    _executions[executionKey] = Execution({
      executionId: executionId,
      commitmentHash: commitmentHash,
      randomWordsHash: bytes32(0),
      requestId: requestId,
      requestedAtBlock: block.number,
      fulfilledAtBlock: 0,
      requester: msg.sender,
      requestedAt: uint64(block.timestamp),
      terminalAt: terminalAt,
      randomWordsAmount: randomWordsAmount,
      finalityBlocks: finalityBlocks,
      status: ExecutionStatus.Requested
    });
  }

  function computeExecutionKey(bytes32 executionId) public view override returns (bytes32 executionKey) {
    executionKey = keccak256(
      abi.encodePacked("chainlink-vrf-service-execution-v1", bytes1(0), block.chainid, address(this), executionId)
    );
  }

  function cancelExecution(bytes32 executionId) external override {
    bytes32 executionKey = computeExecutionKey(executionId);
    require(_executions[executionKey].requester == msg.sender, "VRFHandlerMock: Unauthorized requester");
    require(_executions[executionKey].status == ExecutionStatus.Requested, "VRFHandlerMock: Execution not pending");
    _executions[executionKey].status = ExecutionStatus.Cancelled;
  }

  function expireExecution(bytes32 executionKey) external override {
    Execution storage execution = _executions[executionKey];
    require(execution.status == ExecutionStatus.Requested, "VRFHandlerMock: Execution not pending");
    require(block.timestamp >= execution.terminalAt, "VRFHandlerMock: Execution not expired");
    execution.status = ExecutionStatus.Expired;
  }

  function isExecutionUsable(bytes32 executionKey) external view override returns (bool usable) {
    Execution storage execution = _executions[executionKey];
    uint256 finalityBlocks = uint256(execution.finalityBlocks);
    usable = execution.status == ExecutionStatus.Fulfilled
      && block.number >= execution.requestedAtBlock + finalityBlocks
      && block.number >= execution.fulfilledAtBlock + finalityBlocks;
  }

  function getExecution(bytes32 executionKey) external view override returns (Execution memory execution) {
    execution = _executions[executionKey];
  }

  function mock_fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
    address requester = requestIdToRequester[requestId];
    require(requester != address(0), "VRFHandlerMock: Unknown request ID");

    bytes32 executionKey = _requestIdToExecutionKey[requestId];
    Execution storage execution = _executions[executionKey];
    if (execution.requestId == requestId && execution.status == ExecutionStatus.Requested) {
      if (block.timestamp >= execution.terminalAt) {
        execution.status = ExecutionStatus.Expired;
      } else {
        execution.randomWordsHash = keccak256(abi.encode(randomWords));
        execution.fulfilledAtBlock = block.number;
        execution.status = ExecutionStatus.Fulfilled;
      }
    }

    (bool success,) = requester.call(
      abi.encodeWithSelector(bytes4(keccak256("fulfillRandomWords(uint256,uint256[])")), requestId, randomWords)
    );
    require(success, "VRFHandlerMock: Callback failed");
  }
}
