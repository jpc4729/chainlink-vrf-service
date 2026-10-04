// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// VRF Handler Interface
import { IVRFHandler } from "./IVRFHandler.sol";
// Chainlink
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title VRFHandler - Version-agnostic intermediary for Chainlink VRF random number generation
/// @notice This contract decouples your main contracts from direct integration with Chainlink's VRF,
/// serving as an intermediary that handles random number requests. It allows your contracts to remain
/// unaffected by future VRF version changes (e.g., from VRF 2.0 to 2.5), as you can update or replace
/// the VRFHandler without modifying your main contract's logic. Contracts interact with this handler
/// via the IVRFHandlerReceiver interface, ensuring compatibility with future VRF upgrades.
contract VRFHandler is IVRFHandler, VRFConsumerBaseV2Plus {
  string internal constant EXECUTION_KEY_DOMAIN = "chainlink-vrf-service-execution-v1";

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Types
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @dev Configuration parameters for Chainlink VRF requests
  struct VRFConfig {
    uint256 subscriptionId;
    bytes32 keyHash;
    uint32 callbackGasLimit;
    uint16 requestConfirmations;
    bool nativePaymentEnabled;
  }

  /// @dev Commitment data for verifiable randomness requests
  struct Commitment {
    bytes32 manifestHash;
    uint256 rangeSize;
    uint32 count;
    uint256 committedAt;
    address requester;
  }

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ State variables
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @dev VRF configuration parameters
  VRFConfig internal vrfConfig;

  /// @dev Contract Address => Bool indicating if the contract is allowed to request random numbers
  mapping(address requester => bool isAllowed) public allowedRequesters;

  /// @dev VRF Request ID => Contract that requested the random numbers
  mapping(uint256 requestId => address requester) public vrfRequestIdToRequester;

  /// @dev VRF Fulfilled Request => Bool indicating if the request has been fulfilled
  mapping(uint256 requestId => bool isFulfilled) public vrfFulfilledRequests;

  /// @dev VRF Request ID => Selector of the callback function
  mapping(uint256 requestId => bytes4 selector) public vrfRequestIdToSelector;

  /// @dev Counter of outstanding requests
  uint256 public activeRequests;

  /// @dev VRF Request ID => Commitment data
  mapping(uint256 requestId => Commitment commitment) public commitments;

  /// @dev Domain-separated execution key => immutable request inputs and terminal state
  mapping(bytes32 executionKey => Execution execution) internal executions;

  /// @dev VRF Request ID => domain-separated execution key
  mapping(uint256 requestId => bytes32 executionKey) public vrfRequestIdToExecutionKey;

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Errors
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @dev Emitted when an unauthorized address requests random numbers
  error Unauthorized();

  /// @dev Emitted when the VRF is in an invalid state
  error InvalidVrfState();

  /// @dev Emitted when a parameter provided is invalid
  error InvalidParameter();

  /// @dev Emitted when an execution identity has already consumed its only request
  error ExecutionAlreadyRegistered(bytes32 executionKey);

  /// @dev Emitted when an execution does not exist
  error ExecutionNotFound(bytes32 executionKey);

  /// @dev Emitted when a terminal operation targets an execution that is no longer pending
  error ExecutionNotPending(bytes32 executionKey, ExecutionStatus status);

  /// @dev Emitted when expiration is attempted before the registered terminal time
  error ExecutionNotExpired(bytes32 executionKey, uint64 terminalAt);

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Events
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @dev Emitted when an address is added to the allowed requesters
  event AllowedRequesterAdded(address indexed requester);

  /// @dev Emitted when an address is removed from the allowed requesters
  event AllowedRequesterRemoved(address indexed requester);

  /// @dev Emitted when the request confirmations are set
  event RequestConfirmationsSet(uint16 requestConfirmations);

  /// @dev Emitted when the callback gas limit is set
  event CallbackGasLimitSet(uint32 callbackGasLimit);

  /// @dev Emitted when a random words request is made
  event RandomWordsRequested(uint256 indexed requestId, address indexed requester, uint32 randomWordsAmount);

  /// @dev Emitted when a random words request is fulfilled
  event RandomWordsFulfilled(uint256 indexed requestId, address indexed requester, uint256[] randomWords);

  /// @dev Emitted when the native payment enabled is set
  event NativePaymentEnabledSet(bool nativePaymentEnabled);

  /// @dev Emitted when the VRF configuration is set
  event VrfConfigSet(VRFConfig vrfConfig);

  /// @dev Emitted when a commitment is stored
  event CommitmentStored(uint256 indexed requestId, bytes32 indexed manifestHash, uint256 rangeSize, uint32 count);

  /// @dev Emitted when random words are fulfilled with commitment
  event RandomWordsFulfilledWithCommitment(
    uint256 indexed requestId, bytes32 indexed manifestHash, uint256[] randomWords, uint256[] results
  );

  /// @dev Emitted when a callback to the requester fails — fulfillment still succeeds
  event CallbackFailed(uint256 indexed requestId, address indexed requester, bytes reason);

  /// @dev Emitted when one globally unique immutable execution requests randomness
  event ExecutionRequested(
    bytes32 indexed executionKey,
    uint256 indexed requestId,
    address indexed requester,
    bytes32 executionId,
    bytes32 commitmentHash,
    uint32 randomWordsAmount,
    uint64 terminalAt,
    uint32 finalityBlocks
  );

  /// @dev Emitted when an execution accepts coordinator fulfillment before its terminal time
  event ExecutionFulfilled(
    bytes32 indexed executionKey, uint256 indexed requestId, bytes32 indexed commitmentHash, bytes32 randomWordsHash
  );

  /// @dev Emitted when a requester permanently cancels its pending execution
  event ExecutionCancelled(bytes32 indexed executionKey, uint256 indexed requestId, address indexed requester);

  /// @dev Emitted when a pending execution reaches its terminal time without accepted fulfillment
  event ExecutionExpired(bytes32 indexed executionKey, uint256 indexed requestId);

  /// @dev Emitted when coordinator fulfillment arrives for a cancelled or expired execution
  event ExecutionFulfillmentIgnored(
    bytes32 indexed executionKey, uint256 indexed requestId, ExecutionStatus indexed status
  );

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Constructor
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @notice Initializes the VRFHandler with Chainlink VRF configuration
  /// @param _coordinator The address of the VRF Coordinator
  /// @param _keyHash The key hash for VRF requests
  /// @param _subscriptionId The Chainlink VRF subscription ID
  /// @param _requestConfirmations The number of confirmations to wait before fulfilling a request
  /// @param _callbackGasLimit The gas limit for the callback function
  /// @param _nativePaymentEnabled If true, the contract will use native gas for VRF requests
  constructor(
    address _coordinator,
    bytes32 _keyHash,
    uint256 _subscriptionId,
    uint16 _requestConfirmations,
    uint32 _callbackGasLimit,
    bool _nativePaymentEnabled
  )
    VRFConsumerBaseV2Plus(_coordinator)
  {
    // Input validation
    if (_coordinator == address(0)) revert InvalidParameter();
    if (_keyHash == bytes32(0)) revert InvalidParameter();
    if (_subscriptionId == 0) revert InvalidParameter();
    if (_callbackGasLimit == 0) revert InvalidParameter();

    // Initialize VRF configuration
    vrfConfig = VRFConfig({
      keyHash: _keyHash,
      subscriptionId: _subscriptionId,
      requestConfirmations: _requestConfirmations,
      callbackGasLimit: _callbackGasLimit,
      nativePaymentEnabled: _nativePaymentEnabled
    });
  }

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ External functions
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @notice Request random words without a callback
  /// @dev Random words are emitted via RandomWordsFulfilled event only
  /// @param randomWordsAmount The number of random words to request
  /// @return requestId The unique identifier for this request
  function requestRandomWords(uint32 randomWordsAmount) external returns (uint256 requestId) {
    // Ensure the caller is authorized
    if (!allowedRequesters[msg.sender]) revert Unauthorized();
    if (randomWordsAmount == 0) revert InvalidParameter();

    // Increment the counter of active requests
    unchecked {
      activeRequests++;
    }

    // Create the VRF request
    requestId = _createVRFRequest(randomWordsAmount);

    // No selector stored - bytes4(0) indicates no callback
    // vrfRequestIdToSelector[requestId] remains bytes4(0)

    // Store the requester address for this request ID
    vrfRequestIdToRequester[requestId] = msg.sender;

    // Emit the event
    emit RandomWordsRequested(requestId, msg.sender, randomWordsAmount);
  }

  /// @notice Request random words with a callback
  /// @dev Callback is made to the requester with the specified selector
  /// @param randomWordsAmount The number of random words to request
  /// @param selector The selector of the callback function
  /// @return requestId The unique identifier for this request
  function requestRandomWords(uint32 randomWordsAmount, bytes4 selector) external returns (uint256 requestId) {
    // Ensure the caller is authorized
    if (!allowedRequesters[msg.sender]) revert Unauthorized();
    if (randomWordsAmount == 0) revert InvalidParameter();
    if (selector == bytes4(0)) revert InvalidParameter();

    // Increment the counter of active requests
    unchecked {
      activeRequests++;
    }

    // Create the VRF request
    requestId = _createVRFRequest(randomWordsAmount);

    // Store the selector of the callback function provided by the caller
    vrfRequestIdToSelector[requestId] = selector;

    // Store the requester address for this request ID
    vrfRequestIdToRequester[requestId] = msg.sender;

    // Emit the event
    emit RandomWordsRequested(requestId, msg.sender, randomWordsAmount);
  }

  /// @notice Request random words with a commitment for verifiable selection
  /// @dev Stores commitment data for later verification when random words are fulfilled
  /// @param randomWordsAmount The number of random words to request
  /// @param manifestHash The hash identifying the data set (e.g., IPFS CID)
  /// @param rangeSize The size of the range for result computation (results are 1 to rangeSize)
  /// @return requestId The unique identifier for this request
  function requestRandomWordsWithCommitment(
    uint32 randomWordsAmount,
    bytes32 manifestHash,
    uint256 rangeSize
  )
    external
    returns (uint256 requestId)
  {
    // Ensure the caller is authorized
    if (!allowedRequesters[msg.sender]) revert Unauthorized();
    if (randomWordsAmount == 0) revert InvalidParameter();
    if (manifestHash == bytes32(0)) revert InvalidParameter();
    if (rangeSize == 0) revert InvalidParameter();

    // Increment the counter of active requests
    unchecked {
      activeRequests++;
    }

    // Create the VRF request
    requestId = _createVRFRequest(randomWordsAmount);

    // Store the requester address for this request ID
    vrfRequestIdToRequester[requestId] = msg.sender;

    // Store the commitment data
    commitments[requestId] = Commitment({
      manifestHash: manifestHash,
      rangeSize: rangeSize,
      count: randomWordsAmount,
      committedAt: block.timestamp,
      requester: msg.sender
    });

    // Emit the events
    emit RandomWordsRequested(requestId, msg.sender, randomWordsAmount);
    emit CommitmentStored(requestId, manifestHash, rangeSize, randomWordsAmount);
  }

  /// @inheritdoc IVRFHandler
  function requestRandomWordsForExecution(
    bytes32 executionId,
    bytes32 commitmentHash,
    uint32 randomWordsAmount,
    uint64 terminalAt,
    uint32 finalityBlocks
  )
    external
    returns (uint256 requestId, bytes32 executionKey)
  {
    if (!allowedRequesters[msg.sender]) revert Unauthorized();
    if (
      executionId == bytes32(0) || commitmentHash == bytes32(0) || randomWordsAmount == 0 || finalityBlocks == 0
        || uint256(terminalAt) <= block.timestamp
    ) revert InvalidParameter();

    executionKey = computeExecutionKey(executionId);
    Execution storage execution = executions[executionKey];
    if (execution.status != ExecutionStatus.None) revert ExecutionAlreadyRegistered(executionKey);

    execution.executionId = executionId;
    execution.commitmentHash = commitmentHash;
    execution.requestedAtBlock = block.number;
    execution.requester = msg.sender;
    execution.requestedAt = uint64(block.timestamp);
    execution.terminalAt = terminalAt;
    execution.randomWordsAmount = randomWordsAmount;
    execution.finalityBlocks = finalityBlocks;
    execution.status = ExecutionStatus.Requested;

    unchecked {
      activeRequests++;
    }

    requestId = _createVRFRequest(randomWordsAmount);
    if (requestId == 0) revert InvalidVrfState();

    execution.requestId = requestId;
    vrfRequestIdToRequester[requestId] = msg.sender;
    vrfRequestIdToExecutionKey[requestId] = executionKey;

    emit RandomWordsRequested(requestId, msg.sender, randomWordsAmount);
    emit ExecutionRequested(
      executionKey, requestId, msg.sender, executionId, commitmentHash, randomWordsAmount, terminalAt, finalityBlocks
    );
  }

  /// @inheritdoc IVRFHandler
  function computeExecutionKey(bytes32 executionId) public view returns (bytes32 executionKey) {
    executionKey =
      keccak256(abi.encodePacked(EXECUTION_KEY_DOMAIN, bytes1(0), block.chainid, address(this), executionId));
  }

  /// @inheritdoc IVRFHandler
  function cancelExecution(bytes32 executionId) external {
    bytes32 executionKey = computeExecutionKey(executionId);
    Execution storage execution = executions[executionKey];
    if (execution.status == ExecutionStatus.None) revert ExecutionNotFound(executionKey);
    if (execution.requester != msg.sender) revert Unauthorized();
    if (execution.status != ExecutionStatus.Requested) revert ExecutionNotPending(executionKey, execution.status);

    execution.status = ExecutionStatus.Cancelled;
    emit ExecutionCancelled(executionKey, execution.requestId, msg.sender);
  }

  /// @inheritdoc IVRFHandler
  function expireExecution(bytes32 executionKey) external {
    Execution storage execution = executions[executionKey];
    if (execution.status == ExecutionStatus.None) revert ExecutionNotFound(executionKey);
    if (execution.status != ExecutionStatus.Requested) revert ExecutionNotPending(executionKey, execution.status);
    if (block.timestamp < uint256(execution.terminalAt)) {
      revert ExecutionNotExpired(executionKey, execution.terminalAt);
    }

    execution.status = ExecutionStatus.Expired;
    emit ExecutionExpired(executionKey, execution.requestId);
  }

  /// @inheritdoc IVRFHandler
  function isExecutionUsable(bytes32 executionKey) external view returns (bool usable) {
    Execution storage execution = executions[executionKey];
    if (execution.status != ExecutionStatus.Fulfilled) return false;

    uint256 finalityBlocks = uint256(execution.finalityBlocks);
    usable = block.number >= execution.requestedAtBlock + finalityBlocks
      && block.number >= execution.fulfilledAtBlock + finalityBlocks;
  }

  /// @inheritdoc IVRFHandler
  function getExecution(bytes32 executionKey) external view returns (Execution memory execution) {
    execution = executions[executionKey];
  }

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Internal functions
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @dev Creates a request to the VRF coordinator for random words
  /// @param randomWordsAmount The number of random words to request
  /// @return requestId The unique identifier for this request
  function _createVRFRequest(uint32 randomWordsAmount) internal returns (uint256 requestId) {
    // Request random words from Chainlink's VRF coordinator
    requestId = s_vrfCoordinator.requestRandomWords(
      VRFV2PlusClient.RandomWordsRequest({
        requestConfirmations: vrfConfig.requestConfirmations,
        callbackGasLimit: vrfConfig.callbackGasLimit,
        keyHash: vrfConfig.keyHash,
        subId: vrfConfig.subscriptionId,
        numWords: randomWordsAmount,
        extraArgs: VRFV2PlusClient._argsToBytes(
          VRFV2PlusClient.ExtraArgsV1({ nativePayment: vrfConfig.nativePaymentEnabled })
        )
      })
    );
  }

  /// @dev Callback function called by Chainlink's VRF coordinator when random words are ready
  /// @param _requestId The request ID
  /// @param _randomWords The random numbers
  function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
    // Verify the request hasn't been fulfilled and is valid
    if (vrfFulfilledRequests[_requestId]) revert InvalidVrfState();

    // Get the requester address
    address requester = vrfRequestIdToRequester[_requestId];

    // Get the callback selector
    bytes4 selector = vrfRequestIdToSelector[_requestId];

    // Get the commitment data
    Commitment memory commitment = commitments[_requestId];

    // Verify the requester is valid
    if (requester == address(0)) revert Unauthorized();

    // Update state before external calls

    // Mark the request as fulfilled
    vrfFulfilledRequests[_requestId] = true;

    // Clean up the request data
    delete vrfRequestIdToRequester[_requestId];

    // Clean up the selector
    delete vrfRequestIdToSelector[_requestId];

    // Decrement active requests counter
    unchecked {
      activeRequests--;
    }

    // Emit the fulfillment event
    emit RandomWordsFulfilled(_requestId, requester, _randomWords);

    // Handle commitment if present
    if (commitment.manifestHash != bytes32(0)) {
      // Compute results from random words: (randomWord % rangeSize) + 1
      uint256[] memory results = new uint256[](_randomWords.length);
      for (uint256 i; i < _randomWords.length;) {
        results[i] = (_randomWords[i] % commitment.rangeSize) + 1;
        unchecked {
          ++i;
        }
      }

      // Emit the commitment fulfillment event
      emit RandomWordsFulfilledWithCommitment(_requestId, commitment.manifestHash, _randomWords, results);
    }

    _resolveExecutionFulfillment(_requestId, _randomWords);

    // Only make external call if a callback selector was specified
    // Requests made via requestRandomWordsNoCallback have selector = bytes4(0)
    if (selector != bytes4(0)) {
      // Prepare the callback data with the selector and parameters
      bytes memory callData = abi.encodeWithSelector(selector, _requestId, _randomWords);

      // Mitigates: callback revert/gas-exhaustion DoS — fulfillment must never revert
      // due to a misbehaving receiver, so we catch failures and emit instead of bubbling.
      (bool success, bytes memory reason) = requester.call(callData);
      if (!success) emit CallbackFailed(_requestId, requester, reason);
    }
  }

  /// @dev Accepts execution fulfillment only before its terminal time; cancellation and expiry never free the key
  function _resolveExecutionFulfillment(uint256 requestId, uint256[] calldata randomWords) internal {
    bytes32 executionKey = vrfRequestIdToExecutionKey[requestId];
    Execution storage execution = executions[executionKey];

    // A zero mapping value is valid in theory, so request identity—not the key value—distinguishes legacy requests.
    if (execution.requestId != requestId || execution.status == ExecutionStatus.None) return;

    if (execution.status == ExecutionStatus.Requested && block.timestamp >= uint256(execution.terminalAt)) {
      execution.status = ExecutionStatus.Expired;
      emit ExecutionExpired(executionKey, requestId);
    }

    if (execution.status != ExecutionStatus.Requested) {
      emit ExecutionFulfillmentIgnored(executionKey, requestId, execution.status);
      return;
    }

    bytes32 randomWordsHash = keccak256(abi.encode(randomWords));
    execution.randomWordsHash = randomWordsHash;
    execution.fulfilledAtBlock = block.number;
    execution.status = ExecutionStatus.Fulfilled;

    emit ExecutionFulfilled(executionKey, requestId, execution.commitmentHash, randomWordsHash);
  }

  /*─────────────────────────────────────────────────────────────────────────────────────
  │ Admin functions
  └─────────────────────────────────────────────────────────────────────────────────────*/

  /// @notice Get the VRF configuration
  /// @return vrfConfig_ The VRF configuration
  function getVrfConfig() external view returns (VRFConfig memory vrfConfig_) {
    vrfConfig_ = vrfConfig;
  }

  /// @notice Get the commitment data for a request
  /// @param _requestId The request ID
  /// @return commitment_ The commitment data
  function getCommitment(uint256 _requestId) external view returns (Commitment memory commitment_) {
    commitment_ = commitments[_requestId];
  }

  /// @notice Set the VRF configuration
  /// @param _keyHash The key hash for VRF requests
  /// @param _subscriptionId The Chainlink VRF subscription ID
  /// @param _requestConfirmations The number of confirmations to wait before fulfilling a request
  /// @param _callbackGasLimit The gas limit for the callback function
  /// @param _nativePaymentEnabled If true, the contract will use native gas for VRF requests
  function setVrfConfig(
    bytes32 _keyHash,
    uint256 _subscriptionId,
    uint16 _requestConfirmations,
    uint32 _callbackGasLimit,
    bool _nativePaymentEnabled
  )
    external
    onlyOwner
  {
    // Mitigates: zero-value config bricking all future VRF requests
    if (_keyHash == bytes32(0)) revert InvalidParameter();
    if (_subscriptionId == 0) revert InvalidParameter();
    if (_callbackGasLimit == 0) revert InvalidParameter();

    vrfConfig = VRFConfig({
      keyHash: _keyHash,
      subscriptionId: _subscriptionId,
      requestConfirmations: _requestConfirmations,
      callbackGasLimit: _callbackGasLimit,
      nativePaymentEnabled: _nativePaymentEnabled
    });
    // Emit the event
    emit VrfConfigSet(vrfConfig);
  }

  /// @notice Add an address to the allowed requesters
  /// @param _requester The address to authorize for random number requests
  function addAllowedRequester(address _requester) external onlyOwner {
    if (_requester == address(0)) revert InvalidParameter();
    allowedRequesters[_requester] = true;
    emit AllowedRequesterAdded(_requester);
  }

  /// @notice Remove an address from the allowed requesters
  /// @param _requester The address to remove authorization from
  function removeAllowedRequester(address _requester) external onlyOwner {
    if (_requester == address(0)) revert InvalidParameter();
    allowedRequesters[_requester] = false;
    emit AllowedRequesterRemoved(_requester);
  }

  /// @notice Set the request confirmations
  /// @param _requestConfirmations The number of confirmations to wait
  function setRequestConfirmations(uint16 _requestConfirmations) external onlyOwner {
    vrfConfig.requestConfirmations = _requestConfirmations;
    emit RequestConfirmationsSet(_requestConfirmations);
  }

  /// @notice Set the callback gas limit
  /// @param _callbackGasLimit The gas limit for callbacks
  function setCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
    if (_callbackGasLimit == 0) revert InvalidParameter();
    vrfConfig.callbackGasLimit = _callbackGasLimit;
    emit CallbackGasLimitSet(_callbackGasLimit);
  }

  /// @notice Set the native payment enabled
  /// @param _nativePaymentEnabled If true, the contract will use native gas for VRF requests
  function setNativePaymentEnabled(bool _nativePaymentEnabled) external onlyOwner {
    vrfConfig.nativePaymentEnabled = _nativePaymentEnabled;
    emit NativePaymentEnabledSet(_nativePaymentEnabled);
  }
}
