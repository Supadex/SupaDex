// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockChainlinkAggregator (TEST-ONLY, local chains only)
 * @notice Deployable AggregatorV3-compatible price feed for local anvil seeding and frontend state testing
 *         (LVR healthy / stale / invalid / reverting). It is permissionless on purpose; any caller can move the
 *         price. It can only be deployed on chain 31337 or 1337, so it can never be configured as a real feed.
 *         Production LVR feeds must be official same-chain Chainlink direct-pair proxies (ADR-0009, runbook).
 */
contract MockChainlinkAggregator {
    error LocalChainOnly(uint256 chainId);
    error MockFeedReverting();

    uint8 public immutable decimals;
    string public description;
    uint256 public constant version = 4;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public reverting;

    event MockAnswerSet(uint80 indexed roundId, int256 answer, uint256 updatedAt);
    event MockRevertingSet(bool reverting);

    constructor(uint8 _decimals, string memory _description, int256 initialAnswer) {
        if (block.chainid != 31337 && block.chainid != 1337) revert LocalChainOnly(block.chainid);
        decimals = _decimals;
        description = _description;
        _set(initialAnswer, block.timestamp);
    }

    /// @notice Healthy state: `newAnswer` updated now.
    function setFresh(int256 newAnswer) external {
        _set(newAnswer, block.timestamp);
    }

    /// @notice Stale state: keep the current answer but report it as last updated `age` seconds ago.
    function setStale(uint256 age) external {
        _set(answer, age >= block.timestamp ? 1 : block.timestamp - age);
    }

    /// @notice Invalid state: answer <= 0 (the LVR plugin treats this as fallback reason "invalid answer").
    function setInvalid(int256 nonPositiveAnswer) external {
        require(nonPositiveAnswer <= 0, "must be <= 0");
        _set(nonPositiveAnswer, block.timestamp);
    }

    /// @notice Arbitrary state (answer, updatedAt) for edge cases such as a future timestamp.
    function setRaw(int256 newAnswer, uint256 newUpdatedAt) external {
        _set(newAnswer, newUpdatedAt);
    }

    /// @notice Feed-down state: latestRoundData reverts.
    function setReverting(bool r) external {
        reverting = r;
        emit MockRevertingSet(r);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert MockFeedReverting();
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    function _set(int256 a, uint256 t) internal {
        roundId++;
        answer = a;
        startedAt = t;
        updatedAt = t;
        emit MockAnswerSet(roundId, a, t);
    }
}

/**
 * @title MockSequencerUptimeFeed (TEST-ONLY, local chains only)
 * @notice Chainlink L2 sequencer-uptime feed shape: answer 0 = up, 1 = down; startedAt = time of the last status change.
 */
contract MockSequencerUptimeFeed {
    error LocalChainOnly(uint256 chainId);
    error MockFeedReverting();

    uint8 public constant decimals = 0;
    string public constant description = "Mock L2 Sequencer Uptime Status Feed";

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    bool public reverting;

    event MockSequencerStatus(uint80 indexed roundId, int256 answer, uint256 startedAt);

    constructor() {
        if (block.chainid != 31337 && block.chainid != 1337) revert LocalChainOnly(block.chainid);
        // Up since 1 day ago (past any grace period) unless block.timestamp is small.
        _set(0, block.timestamp > 1 days ? block.timestamp - 1 days : 1);
    }

    /// @notice Sequencer up, status changed `sinceSecondsAgo` ago (< grace ⇒ plugin still falls back).
    function setUp(uint256 sinceSecondsAgo) external {
        _set(0, sinceSecondsAgo >= block.timestamp ? 1 : block.timestamp - sinceSecondsAgo);
    }

    /// @notice Sequencer down since now.
    function setDown() external {
        _set(1, block.timestamp);
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert MockFeedReverting();
        return (roundId, answer, startedAt, startedAt, roundId);
    }

    function _set(int256 a, uint256 s) internal {
        roundId++;
        answer = a;
        startedAt = s;
        emit MockSequencerStatus(roundId, a, s);
    }
}
