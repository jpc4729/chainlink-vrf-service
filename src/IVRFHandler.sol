// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IVRFHandler {
  enum ExecutionStatus {
    None,
    Requested,
    Fulfilled,
    Cancelled,
    Expired
  }

  struct Execution {
    bytes32 executionId;
    bytes32 commitmentHash;
    bytes32 randomWordsHash;
    uint256 requestId;
    uint256 requestedAtBlock;
    uint256 fulfilledAtBlock;
    address requester;
    uint64 requestedAt;
    uint64 terminalAt;
    uint32 randomWordsAmount;
    uint32 finalityBlocks;
    ExecutionStatus status;
  }

  /// @notice Request random words without a callback
  /// @dev Random words are emitted via RandomWordsFulfilled event only
  /// @param randomWordsAmount The number of random words to request
  /// @return requestId The request ID
  function requestRandomWords(uint32 randomWordsAmount) external returns (uint256 requestId);

  /// @notice Request random words with a callback
  /// @param randomWordsAmount The number of random words to request
  /// @param selector The selector of the callback function
  /// @return requestId The request ID
  function requestRandomWords(uint32 randomWordsAmount, bytes4 selector) external returns (uint256 requestId);

  /// @notice Request random words with a commitment for verifiable selection
  /// @param randomWordsAmount The number of random words to request
  /// @param manifestHash The hash identifying the data set (e.g., IPFS CID)
  /// @param rangeSize The size of the range for result computation (results are 1 to rangeSize)
  /// @return requestId The request ID
  function requestRandomWordsWithCommitment(
    uint32 randomWordsAmount,
    bytes32 manifestHash,
    uint256 rangeSize
  )
    external
    returns (uint256 requestId);

  /// @notice Registers one immutable randomness request for a globally unique execution
  /// @param executionId Opaque globally unique identity that can never be requested twice
  /// @param commitmentHash Opaque digest binding the caller's execution inputs
  /// @param randomWordsAmount Number of random words requested from the coordinator
  /// @param terminalAt First Unix timestamp at which an unfulfilled execution is expired
  /// @param finalityBlocks Additional blocks required after request and fulfillment inclusion
  /// @return requestId Chainlink request identifier
  /// @return executionKey Domain-separated identity derived by the handler
  function requestRandomWordsForExecution(
    bytes32 executionId,
    bytes32 commitmentHash,
    uint32 randomWordsAmount,
    uint64 terminalAt,
    uint32 finalityBlocks
  )
    external
    returns (uint256 requestId, bytes32 executionKey);

  /// @notice Computes the domain-separated key used for an execution
  /// @param executionId Opaque globally unique execution identity
  /// @return executionKey Handler- and chain-scoped execution key
  function computeExecutionKey(bytes32 executionId) external view returns (bytes32 executionKey);

  /// @notice Permanently cancels a pending execution without freeing its identity for another request
  /// @param executionId Opaque execution identity owned by the caller
  function cancelExecution(bytes32 executionId) external;

  /// @notice Marks an overdue pending execution expired; callable by any address
  /// @param executionKey Domain-separated execution key
  function expireExecution(bytes32 executionKey) external;

  /// @notice Returns whether an accepted fulfillment has reached registered request and fulfillment finality
  /// @param executionKey Domain-separated execution key
  /// @return usable True only when the execution is fulfilled and both finality thresholds have passed
  function isExecutionUsable(bytes32 executionKey) external view returns (bool usable);

  /// @notice Returns the immutable inputs and current state for an execution
  /// @param executionKey Domain-separated execution key
  /// @return execution Stored execution data, or zero values when unknown
  function getExecution(bytes32 executionKey) external view returns (Execution memory execution);
}
