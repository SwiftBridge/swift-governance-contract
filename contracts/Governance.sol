// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Governance
 * @dev A DAO governance contract for Swift v2 platform
 * @author Swift v2 Team
 */
contract Governance is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        string description,
        uint256 startTime,
        uint256 endTime
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 support,
        uint256 weight,
        string reason
    );

    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor
    );

    event ProposalCancelled(
        uint256 indexed proposalId,
        address indexed proposer
    );

    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    // Structs
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) votes;
    }

    struct ProposalAction {
        address target;
        uint256 value;
        string signature;
        bytes data;
    }

    struct Delegate {
        address delegate;
        uint256 delegatedVotes;
        uint256 lastDelegationTime;
    }

    // State variables
    Counters.Counter private _proposalIdCounter;
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ProposalAction[]) public proposalActions;
    mapping(address => Delegate) public delegates;
    mapping(address => uint256) public votingPower;
    mapping(address => bool) public isWhitelisted;
    
    IERC20 public governanceToken;
    
    uint256 public constant VOTING_DELAY = 1 days;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant PROPOSAL_THRESHOLD = 1000 * 10**18; // 1000 tokens
    uint256 public constant QUORUM_THRESHOLD = 10000 * 10**18; // 10000 tokens
    uint256 public constant EXECUTION_DELAY = 1 days;

    // Modifiers
    modifier onlyWhitelisted() {
        require(isWhitelisted[msg.sender] || msg.sender == owner(), "Not whitelisted");
        _;
    }

    modifier proposalExists(uint256 _proposalId) {
        require(_proposalId > 0 && _proposalId <= _proposalIdCounter.current(), "Proposal does not exist");
        _;
    }

    modifier proposalActive(uint256 _proposalId) {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.startTime, "Voting not started");
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!proposal.executed, "Proposal executed");
        require(!proposal.cancelled, "Proposal cancelled");
        _;
    }

    modifier proposalExecutable(uint256 _proposalId) {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.endTime + EXECUTION_DELAY, "Execution delay not met");
        require(!proposal.executed, "Proposal executed");
        require(!proposal.cancelled, "Proposal cancelled");
        require(proposal.forVotes > proposal.againstVotes, "Proposal not passed");
        require(proposal.forVotes + proposal.againstVotes + proposal.abstainVotes >= QUORUM_THRESHOLD, "Quorum not met");
        _;
    }

    constructor(address _governanceToken) {
        require(_governanceToken != address(0), "Invalid governance token address");
        governanceToken = IERC20(_governanceToken);
        _proposalIdCounter.increment();
        isWhitelisted[msg.sender] = true;
    }

    /**
     * @dev Create a new proposal
     * @param _title Title of the proposal
     * @param _description Description of the proposal
     * @param _actions Array of actions to execute if proposal passes
     */
    function createProposal(
        string memory _title,
        string memory _description,
        ProposalAction[] memory _actions
    ) external onlyWhitelisted returns (uint256 proposalId) {
        require(votingPower[msg.sender] >= PROPOSAL_THRESHOLD, "Insufficient voting power");
        require(bytes(_title).length > 0, "Title required");
        require(bytes(_description).length > 0, "Description required");
        require(_actions.length > 0, "Actions required");

        proposalId = _proposalIdCounter.current();
        _proposalIdCounter.increment();

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = _title;
        proposal.description = _description;
        proposal.startTime = block.timestamp + VOTING_DELAY;
        proposal.endTime = block.timestamp + VOTING_DELAY + VOTING_PERIOD;
        proposal.executed = false;
        proposal.cancelled = false;

        // Add actions
        for (uint256 i = 0; i < _actions.length; i++) {
            proposalActions[proposalId].push(_actions[i]);
        }

        emit ProposalCreated(proposalId, msg.sender, _title, _description, proposal.startTime, proposal.endTime);
    }

    /**
     * @dev Vote on a proposal
     * @param _proposalId ID of the proposal
     * @param _support Support level (0 = against, 1 = for, 2 = abstain)
     * @param _reason Reason for the vote
     */
    function vote(
        uint256 _proposalId,
        uint8 _support,
        string memory _reason
    ) external proposalExists(_proposalId) proposalActive(_proposalId) {
        require(_support <= 2, "Invalid support value");
        
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.hasVoted[msg.sender], "Already voted");

        uint256 weight = votingPower[msg.sender];
        require(weight > 0, "No voting power");

        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = weight;

        if (_support == 0) {
            proposal.againstVotes += weight;
        } else if (_support == 1) {
            proposal.forVotes += weight;
        } else if (_support == 2) {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(_proposalId, msg.sender, _support, weight, _reason);
    }

    /**
     * @dev Execute a proposal
     * @param _proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) 
        external 
        proposalExists(_proposalId) 
        proposalExecutable(_proposalId) 
        nonReentrant 
    {
        Proposal storage proposal = proposals[_proposalId];
        proposal.executed = true;

        ProposalAction[] storage actions = proposalActions[_proposalId];
        for (uint256 i = 0; i < actions.length; i++) {
            ProposalAction storage action = actions[i];

            bytes memory callData;
            if (bytes(action.signature).length == 0) {
                callData = action.data;
            } else {
                callData = abi.encodePacked(bytes4(keccak256(bytes(action.signature))), action.data);
            }

            (bool success, ) = action.target.call{value: action.value}(callData);
            require(success, "Action execution failed");
        }

        emit ProposalExecuted(_proposalId, msg.sender);
    }

    /**
     * @dev Cancel a proposal (only proposer can cancel)
     * @param _proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 _proposalId) 
        external 
        proposalExists(_proposalId) 
    {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.proposer == msg.sender, "Only proposer can cancel");
        require(!proposal.executed, "Proposal executed");
        require(!proposal.cancelled, "Proposal cancelled");

        proposal.cancelled = true;
        emit ProposalCancelled(_proposalId, msg.sender);
    }

    /**
     * @dev Delegate voting power to another address
     * @param _delegate Address to delegate to
     */
    function delegate(address _delegate) external {
        require(_delegate != address(0), "Invalid delegate");
        require(_delegate != msg.sender, "Cannot delegate to self");

        Delegate storage currentDelegate = delegates[msg.sender];
        address fromDelegate = currentDelegate.delegate;
        
        if (fromDelegate != address(0)) {
            votingPower[fromDelegate] -= currentDelegate.delegatedVotes;
        }

        currentDelegate.delegate = _delegate;
        currentDelegate.delegatedVotes = governanceToken.balanceOf(msg.sender);
        currentDelegate.lastDelegationTime = block.timestamp;

        votingPower[_delegate] += currentDelegate.delegatedVotes;

        emit DelegateChanged(msg.sender, fromDelegate, _delegate);
    }

    /**
     * @dev Update voting power (called by token contract)
     * @param _user Address of the user
     * @param _newBalance New token balance
     */
    function updateVotingPower(address _user, uint256 _newBalance) external {
        require(msg.sender == address(governanceToken), "Only token contract can update");
        
        Delegate storage userDelegate = delegates[_user];
        if (userDelegate.delegate != address(0)) {
            votingPower[userDelegate.delegate] = votingPower[userDelegate.delegate] - userDelegate.delegatedVotes + _newBalance;
            userDelegate.delegatedVotes = _newBalance;
        } else {
            votingPower[_user] = _newBalance;
        }
    }

    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId)
        returns (
            uint256 id,
            address proposer,
            string memory title,
            string memory description,
            uint256 startTime,
            uint256 endTime,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bool executed,
            bool cancelled
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.executed,
            proposal.cancelled
        );
    }

    /**
     * @dev Get proposal actions
     * @param _proposalId ID of the proposal
     * @return Array of proposal actions
     */
    function getProposalActions(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId)
        returns (ProposalAction[] memory) 
    {
        return proposalActions[_proposalId];
    }

    /**
     * @dev Check if user has voted on proposal
     * @param _proposalId ID of the proposal
     * @param _user Address of the user
     * @return True if user has voted
     */
    function hasVoted(uint256 _proposalId, address _user) 
        external 
        view 
        proposalExists(_proposalId)
        returns (bool) 
    {
        return proposals[_proposalId].hasVoted[_user];
    }

    /**
     * @dev Get user's voting power
     * @param _user Address of the user
     * @return Voting power
     */
    function getVotingPower(address _user) external view returns (uint256) {
        return votingPower[_user];
    }

    /**
     * @dev Whitelist an address
     * @param _address Address to whitelist
     */
    function whitelistAddress(address _address) external onlyOwner {
        isWhitelisted[_address] = true;
    }

    /**
     * @dev Remove address from whitelist
     * @param _address Address to remove
     */
    function removeFromWhitelist(address _address) external onlyOwner {
        isWhitelisted[_address] = false;
    }

    /**
     * @dev Get total proposal count
     * @return Total number of proposals
     */
    function getTotalProposalCount() external view returns (uint256) {
        return _proposalIdCounter.current() - 1;
    }

    /**
     * @dev Get proposal state
     * @param _proposalId ID of the proposal
     * @return State of the proposal
     */
    function getProposalState(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId)
        returns (string memory) 
    {
        Proposal storage proposal = proposals[_proposalId];
        
        if (proposal.cancelled) {
            return "Cancelled";
        }
        
        if (proposal.executed) {
            return "Executed";
        }
        
        if (block.timestamp < proposal.startTime) {
            return "Pending";
        }
        
        if (block.timestamp <= proposal.endTime) {
            return "Active";
        }
        
        if (proposal.forVotes <= proposal.againstVotes) {
            return "Defeated";
        }
        
        if (proposal.forVotes + proposal.againstVotes + proposal.abstainVotes < QUORUM_THRESHOLD) {
            return "Defeated";
        }
        
        if (block.timestamp <= proposal.endTime + EXECUTION_DELAY) {
            return "Succeeded";
        }
        
        return "Queued";
    }
}
