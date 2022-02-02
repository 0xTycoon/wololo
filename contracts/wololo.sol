pragma solidity 0.8.11;
/**
* Wololo - a Moloch v2 mod that implements a DAO for the CEO of CryptoPunks (CIG)
*/
//import "./SafeMath.sol"; // solidity 0.8 does this


contract Moloch  {

    /***************
    GLOBAL CONSTANTS
    ***************/
    uint256 public periodDuration; // default = 17280 = 4.8 hours in seconds (5 periods per day)
    uint256 public votingPeriodLength; // default = 35 periods (7 days)
    uint256 public gracePeriodLength; // default = 35 periods (7 days)
    uint256 public proposalDeposit; // default = 10 ETH (~$1,000 worth of ETH at contract deployment)
    uint256 public dilutionBound; // default = 3 - maximum multiplier a YES voter will be obligated to pay in case of mass ragequit
    uint256 public processingReward; // default = 0.1 - amount of ETH to give to whoever processes a proposal
    uint256 public summoningTime; // needed to determine the current period

    address public depositToken; // deposit token contract reference; default = wETH

    // HARD-CODED LIMITS
    // These numbers are quite arbitrary; they are small enough to avoid overflows when doing calculations
    // with periods or shares, yet big enough to not limit reasonable use cases.
    uint256 constant MAX_VOTING_PERIOD_LENGTH = 10**18; // maximum length of voting period
    uint256 constant MAX_GRACE_PERIOD_LENGTH = 10**18; // maximum length of grace period
    uint256 constant MAX_DILUTION_BOUND = 10**18; // maximum dilution bound
    uint256 constant MAX_NUMBER_OF_SHARES_AND_LOOT = 10**18; // maximum number of shares that can be minted
    uint256 constant MAX_TOKEN_WHITELIST_COUNT = 400; // maximum number of whitelisted tokens
    uint256 constant MAX_TOKEN_GUILDBANK_COUNT = 200; // maximum number of tokens with non-zero balance in guildbank

    // ***************
    // EVENTS
    // ***************
    event SummonComplete(
        address indexed summoner,
        address[] tokens,
        uint256 summoningTime,
        uint256 periodDuration,
        uint256 votingPeriodLength,
        uint256 gracePeriodLength,
        uint256 proposalDeposit,
        uint256 dilutionBound,
        uint256 processingReward);
    event SubmitProposal(
        address indexed applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        bytes32 details,
        ProposalAction action,
        uint256 proposalId,
        address indexed delegateKey,
        address indexed memberAddress);
    event SponsorProposal(
        address indexed delegateKey,
        address indexed memberAddress,
        uint256 proposalId,
        uint256 proposalIndex,
        uint256 startingPeriod);
    event SubmitVote(
        uint256 proposalId,
        uint256 indexed proposalIndex,
        address indexed delegateKey,
        address indexed memberAddress,
        uint8 uintVote);
    event ProcessProposal(
        uint256 indexed proposalIndex,
        uint256 indexed proposalId,
        bool didPass);
    event ProcessWhitelistProposal(
        uint256 indexed proposalIndex,
        uint256 indexed proposalId,
        bool didPass);
    event ProcessGuildKickProposal(
        uint256 indexed proposalIndex,
        uint256 indexed proposalId,
        bool didPass);
    event Ragequit(
        address indexed memberAddress,
        uint256 sharesToBurn,
        uint256 lootToBurn);
    event TokensCollected(
        address indexed token,
        uint256 amountToCollect);
    event CancelProposal(
        uint256 indexed proposalId,
        address applicantAddress);
    event UpdateDelegateKey(
        address indexed memberAddress,
        address newDelegateKey);
    event Withdraw(
        address indexed memberAddress,
        address token,
        uint256 amount);

    // *******************
    // INTERNAL ACCOUNTING
    // *******************

    struct Totals {
        uint256 proposalCount; // total proposals submitted
        uint256 totalShares; // total shares across all members
        uint256 totalLoot; // total loot across all members
        uint256 totalGuildBankTokens; // total tokens with non-zero balance in guild bank
    }
    Totals public totals;


    address public constant GUILD = address(0xdead);
    address public constant ESCROW = address(0xbeef);
    address public constant TOTAL = address(0xbabe);
    mapping (address => mapping(address => uint256)) public userTokenBalances; // userTokenBalances[userAddress][tokenAddress]

    enum Vote {
        Null, // default value, counted as abstention
        Yes,
        No
    }

    enum ProposalAction {
        Join,
        GuildKick, // flags[5]
        Grant,
        Whitelist, // flags[4]
        Harvest,
        BuyCEO,
        SetPrice,
        RewardTarget,
        DepositTax,
        SetBaseUri
    }

    enum ProposalState {
        Proposed,
        Sponsored, // flags[0]
        Cancelled, // flags[3]
        Passed,    // flags[2]
        Processed  // flags[1]
    }

    struct Member {
        address delegateKey; // the key responsible for submitting proposals and voting - defaults to member address unless updated
        uint256 shares; // the # of voting shares assigned to this member
        uint256 loot; // the loot amount available to this member (combined with shares on ragequit)
        bool exists; // always true once a member has been created
        uint256 highestIndexYesVote; // highest proposal index # on which the member voted YES
        uint256 jailed; // set to proposalIndex of a passing guild kick proposal for this member, prevents voting on and sponsoring proposals
    }

    struct ProposalMutable {
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal
        ProposalState state; // processing state (it was in flags before)
        uint256 maxTotalSharesAndLootAtYesVote; // the maximum # of total shares encountered at a yes vote on this proposal
    }

    struct Proposal {
        address applicant; // the applicant who wishes to become a member - this key will be used for withdrawals (doubles as guild kick target for gkick proposals)
        address proposer; // the account that submitted the proposal (can be non-member)
        address sponsor; // the member that sponsored the proposal (moving it into the queue)
        uint256 sharesRequested; // the # of shares the applicant is requesting
        uint256 lootRequested; // the amount of loot the applicant is requesting
        uint256 tributeOffered; // amount of tokens offered as tribute
        address tributeToken; // tribute token contract reference
        uint256 paymentRequested; // amount of tokens requested as payment
        address paymentToken; // payment token contract reference
        uint256 startingPeriod; // the period in which voting can start for this proposal
        bytes32 details; // proposal details - could be IPFS hash, plaintext, or JSON
        ProposalAction action; // what action will the proposal do (it was recorded in flags before)
    }
    mapping (address => mapping(uint256 => Vote)) votesByMember; // the votes on each proposal by each member
    mapping(uint256 => ProposalMutable) public pState; // keeps variables that can mutate for a proposal
    mapping(address => bool) public tokenWhitelist;
    address[] public approvedTokens;

    mapping(address => bool) public proposedToWhitelist;
    mapping(address => bool) public proposedToKick;

    mapping(address => Member) public members;
    mapping(address => address) public memberAddressByDelegateKey;

    mapping(uint256 => Proposal) public proposals;


    uint256[] public proposalQueue;

    modifier onlyMember {
        require(members[msg.sender].shares > 0 || members[msg.sender].loot > 0, "not a member");
        _;
    }

    modifier onlyShareholder {
        require(members[msg.sender].shares > 0, "not a shareholder");
        _;
    }

    modifier onlyDelegate {
        require(members[memberAddressByDelegateKey[msg.sender]].shares > 0, "not a delegate");
        _;
    }

    constructor(
        address _summoner,
        address[] memory _approvedTokens,
        uint256 _periodDuration,
        uint256 _votingPeriodLength,
        uint256 _gracePeriodLength,
        uint256 _proposalDeposit,
        uint256 _dilutionBound,
        uint256 _processingReward
    ) {
        require(_summoner != address(0), "summoner cannot be 0");
        require(_periodDuration > 0, "_periodDuration cannot be 0");
        require(_votingPeriodLength > 0, "_votingPeriodLength cannot be 0");
        require(_votingPeriodLength <= MAX_VOTING_PERIOD_LENGTH, "_votingPeriodLength exceeds limit");
        require(_gracePeriodLength <= MAX_GRACE_PERIOD_LENGTH, "_gracePeriodLength exceeds limit");
        require(_dilutionBound > 0, "_dilutionBound cannot be 0");
        require(_dilutionBound <= MAX_DILUTION_BOUND, "_dilutionBound exceeds limit");
        require(_approvedTokens.length > 0, "need at least one approved token");
        require(_approvedTokens.length <= MAX_TOKEN_WHITELIST_COUNT, "too many tokens");
        require(_proposalDeposit >= _processingReward, "_proposalDeposit cannot be smaller than _processingReward");

        depositToken = _approvedTokens[0];
        // NOTE: move event up here, avoid stack too deep if too many approved tokens
        emit SummonComplete(_summoner, _approvedTokens, block.timestamp, _periodDuration, _votingPeriodLength, _gracePeriodLength, _proposalDeposit, _dilutionBound, _processingReward);


        for (uint256 i = 0; i < _approvedTokens.length; i++) {
            require(_approvedTokens[i] != address(0), "_approvedToken cannot be 0");
            require(!tokenWhitelist[_approvedTokens[i]], "duplicate approved token");
            tokenWhitelist[_approvedTokens[i]] = true;
            approvedTokens.push(_approvedTokens[i]);
        }

        periodDuration = _periodDuration;
        votingPeriodLength = _votingPeriodLength;
        gracePeriodLength = _gracePeriodLength;
        proposalDeposit = _proposalDeposit;
        dilutionBound = _dilutionBound;
        processingReward = _processingReward;

        summoningTime = block.timestamp;

        members[_summoner] = Member(_summoner, 1, 0, true, 0, 0);
        memberAddressByDelegateKey[_summoner] = _summoner;
        totals.totalShares = 1;

    }

    /*****************
    PROPOSAL FUNCTIONS
    *****************/
    function submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        bytes32 details
    ) public returns (uint256 proposalId) {
        require(sharesRequested + lootRequested <= MAX_NUMBER_OF_SHARES_AND_LOOT, "too many shares requested");
        require(tokenWhitelist[tributeToken], "tributeToken is not whitelisted");
        require(tokenWhitelist[paymentToken], "payment is not whitelisted");
        require(applicant != address(0), "applicant cannot be 0");
        require(applicant != GUILD && applicant != ESCROW && applicant != TOTAL, "applicant address cannot be reserved");
        require(members[applicant].jailed == 0, "proposal applicant must not be jailed");

        if (tributeOffered > 0 && userTokenBalances[GUILD][tributeToken] == 0) {
            require(totals.totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, 'cannot submit more tribute proposals for new tokens - guildbank is full');
        }

        // collect tribute from proposer and store it in the Moloch until the proposal is processed
        require(IERC20(tributeToken).transferFrom(msg.sender, address(this), tributeOffered), "tribute token transfer failed");
        unsafeAddToBalance(ESCROW, tributeToken, tributeOffered);
        ProposalAction action;
        if (paymentRequested > 0) {
            action = ProposalAction.Grant;
        } else {
            action = ProposalAction.Join;
        }
        _submitProposal(applicant, sharesRequested, lootRequested, tributeOffered, tributeToken, paymentRequested, paymentToken, details, action);
        unchecked {
            return totals.proposalCount - 1;
        }
    }

    function submitWhitelistProposal(address tokenToWhitelist, bytes32 details) public returns (uint256 proposalId) {
        require(tokenToWhitelist != address(0), "must provide token address");
        require(!tokenWhitelist[tokenToWhitelist], "cannot already have whitelisted the token");
        require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "cannot submit more whitelist proposals");

        ProposalAction action = ProposalAction.Whitelist;

        _submitProposal(address(0), 0, 0, 0, tokenToWhitelist, 0, address(0), details, action);
        unchecked {
            return totals.proposalCount - 1;
        }
    }

    function submitGuildKickProposal(address memberToKick, bytes32 details) public returns (uint256 proposalId) {
        Member memory member = members[memberToKick];

        require(member.shares > 0 || member.loot > 0, "member must have at least one share or one loot");
        require(members[memberToKick].jailed == 0, "member must not already be jailed");

        ProposalAction action = ProposalAction.GuildKick;

        _submitProposal(memberToKick, 0, 0, 0, address(0), 0, address(0), details, action);
        unchecked {
            return totals.proposalCount - 1;
        }
    }

    function _submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        bytes32 details,
        ProposalAction action
    ) internal {
        Proposal storage p = proposals[totals.proposalCount];
        p.applicant = applicant;
        p.proposer = msg.sender;
        //p.sponsor = address(0);
        p.sharesRequested = sharesRequested;
        p.lootRequested = lootRequested;
        p.tributeOffered = tributeOffered;
        p.tributeToken = tributeToken;
        p.paymentRequested = paymentRequested;
        p.paymentToken = paymentToken;
        //p.startingPeriod = 0;
        p.action = action;
        p.details = details;

        address memberAddress = memberAddressByDelegateKey[msg.sender];
        // NOTE: argument order matters, avoid stack too deep
        emit SubmitProposal(
            applicant,
            sharesRequested,
            lootRequested,
            tributeOffered,
            tributeToken,
            paymentRequested,
            paymentToken,
            details,
            action,
            totals.proposalCount,
            msg.sender,
            memberAddress);
        unchecked {
            totals.proposalCount += 1;
        }

    }

    function sponsorProposal(uint256 proposalId) public onlyDelegate {
        // collect proposal deposit from sponsor and store it in the Moloch until the proposal is processed
        require(IERC20(depositToken).transferFrom(msg.sender, address(this), proposalDeposit), "proposal deposit token transfer failed");
        unsafeAddToBalance(ESCROW, depositToken, proposalDeposit);

        Proposal storage proposal = proposals[proposalId];
        ProposalMutable storage s = pState[proposalId];

        require(proposal.proposer != address(0), 'proposal must have been proposed');
        require(s.state == ProposalState.Proposed, "proposal not in proposed state");

        require(members[proposal.applicant].jailed == 0, "proposal applicant must not be jailed");

        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0) {
            require(totals.totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, 'cannot sponsor more tribute proposals for new tokens - guildbank is full');
        }

        // whitelist proposal
        if (proposal.action == ProposalAction.Whitelist) {
            require(!tokenWhitelist[address(proposal.tributeToken)], "cannot already have whitelisted the token");
            require(!proposedToWhitelist[address(proposal.tributeToken)], 'already proposed to whitelist');
            require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "cannot sponsor more whitelist proposals");
            proposedToWhitelist[address(proposal.tributeToken)] = true;

            // guild kick proposal
        } else if (proposal.action == ProposalAction.GuildKick) {
            require(!proposedToKick[proposal.applicant], 'already proposed to kick');
            proposedToKick[proposal.applicant] = true;
        }

        // compute startingPeriod for proposal
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0 ? 0 : proposals[proposalQueue[proposalQueue.length - 1]].startingPeriod
        ) + 1;

        proposal.startingPeriod = startingPeriod;

        address memberAddress = memberAddressByDelegateKey[msg.sender];
        proposal.sponsor = memberAddress;

        s.state = ProposalState.Sponsored; // sponsored

        // append proposal to the queue
        proposalQueue.push(proposalId);

        emit SponsorProposal(msg.sender, memberAddress, proposalId, proposalQueue.length - 1, startingPeriod);
    }

    // NOTE: In MolochV2 proposalIndex !== proposalId
    function submitVote(uint256 proposalIndex, uint8 uintVote) public onlyDelegate {
        address memberAddress = memberAddressByDelegateKey[msg.sender];
        Member storage member = members[memberAddress];
        Vote  voteRecord = votesByMember[memberAddress][proposalIndex];
        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];
        ProposalMutable storage s = pState[proposalQueue[proposalIndex]];
        require(uintVote < 3, "must be less than 3");
        Vote vote = Vote(uintVote);

        require(getCurrentPeriod() >= proposal.startingPeriod, "voting period has not started");
        require(!hasVotingPeriodExpired(proposal.startingPeriod), "proposal voting period has expired");
        require(voteRecord == Vote.Null, "member has already voted");
        require(vote == Vote.Yes || vote == Vote.No, "vote must be either Yes or No");

        votesByMember[memberAddress][proposalIndex] = vote;

        if (vote == Vote.Yes) {
            s.yesVotes = s.yesVotes + member.shares;

            // set highest index (latest) yes vote - must be processed for member to ragequit
            if (proposalIndex > member.highestIndexYesVote) {
                member.highestIndexYesVote = proposalIndex;
            }

            // set maximum of total shares encountered at a yes vote - used to bound dilution for yes voters
            if (totals.totalShares + totals.totalLoot > s.maxTotalSharesAndLootAtYesVote) {
                s.maxTotalSharesAndLootAtYesVote = totals.totalShares + totals.totalLoot;
            }

        } else if (vote == Vote.No) {
            s.noVotes = s.noVotes + member.shares;
        }

        // NOTE: subgraph indexes by proposalId not proposalIndex since proposalIndex isn't set untill it's been sponsored but proposal is created on submission
        emit SubmitVote(proposalQueue[proposalIndex], proposalIndex, msg.sender, memberAddress, uintVote);
    }

    function processProposal(uint256 proposalIndex) public {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal memory proposal = proposals[proposalId];
        ProposalMutable storage s = pState[proposalId];
        require(
            proposal.action == ProposalAction.Join ||
            proposal.action == ProposalAction.Grant,
            "must be a standard proposal"
        );
        s.state = ProposalState.Processed; // TODO unnecessary write
        bool didPass = _didPass(proposalIndex);
        // Make the proposal fail if the new total number of shares and loot exceeds the limit
        if (totals.totalShares
                + totals.totalLoot
                + proposal.sharesRequested
                + proposal.lootRequested > MAX_NUMBER_OF_SHARES_AND_LOOT) {
            didPass = false;
        }
        // Make the proposal fail if it is requesting more tokens as payment than the available guild bank balance
        if (proposal.paymentRequested > userTokenBalances[GUILD][proposal.paymentToken]) {
            didPass = false;
        }
        // Make the proposal fail if it would result in too many tokens with non-zero balance in guild bank
        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0 && totals.totalGuildBankTokens >= MAX_TOKEN_GUILDBANK_COUNT) {
            didPass = false;
        }

        // PROPOSAL PASSED
        if (didPass) {
            s.state = ProposalState.Passed;
            // if the applicant is already a member, add to their existing shares & loot
            if (members[proposal.applicant].exists) {
                members[proposal.applicant].shares =
                    members[proposal.applicant].shares + proposal.sharesRequested;
                members[proposal.applicant].loot =
                    members[proposal.applicant].loot + proposal.lootRequested;
                // the applicant is a new member, create a new record for them
            } else {
                // if the applicant address is already taken by a member's delegateKey, reset it to their member address
                if (members[memberAddressByDelegateKey[proposal.applicant]].exists) {
                    address memberToOverride = memberAddressByDelegateKey[proposal.applicant];
                    memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                    members[memberToOverride].delegateKey = memberToOverride;
                }
                // use applicant address as delegateKey by default
                members[proposal.applicant] = Member(proposal.applicant, proposal.sharesRequested, proposal.lootRequested, true, 0, 0);
                memberAddressByDelegateKey[proposal.applicant] = proposal.applicant;
            }
            // mint new shares & loot
            totals.totalShares = totals.totalShares + proposal.sharesRequested;
            totals.totalLoot = totals.totalLoot + proposal.lootRequested;
            // if the proposal tribute is the first tokens of its kind to make it into the guild bank, increment total guild bank tokens
            if (userTokenBalances[GUILD][proposal.tributeToken] == 0 && proposal.tributeOffered > 0) {
                unchecked {
                    totals.totalGuildBankTokens += 1;
                }
            }
            unsafeInternalTransfer(ESCROW, GUILD, proposal.tributeToken, proposal.tributeOffered);
            unsafeInternalTransfer(GUILD, proposal.applicant, proposal.paymentToken, proposal.paymentRequested);
            // if the proposal spends 100% of guild bank balance for a token, decrement total guild bank tokens
            if (userTokenBalances[GUILD][proposal.paymentToken] == 0 && proposal.paymentRequested > 0) {
                unchecked {
                    totals.totalGuildBankTokens -= 1;
                }
            }
            // PROPOSAL FAILED
        } else {
            // return all tokens to the proposer (not the applicant, because funds come from proposer)
            unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);
        }
        _returnDeposit(proposal.sponsor);
        emit ProcessProposal(proposalIndex, proposalId, didPass);
    }

    function processWhitelistProposal(uint256 proposalIndex) public {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal memory proposal = proposals[proposalId];
        ProposalMutable storage s = pState[proposalId];
        require(proposal.action == ProposalAction.Whitelist, "must be a whitelist proposal");
        // TODO optimize s.state so that we are not writing twice to it
        s.state = ProposalState.Processed; // processed
        bool didPass = _didPass(proposalIndex);
        if (approvedTokens.length >= MAX_TOKEN_WHITELIST_COUNT) {
            didPass = false;
        }
        if (didPass) {
            s.state = ProposalState.Passed; // didPass
            tokenWhitelist[address(proposal.tributeToken)] = true;
            approvedTokens.push(proposal.tributeToken);
        }
        proposedToWhitelist[address(proposal.tributeToken)] = false;
        _returnDeposit(proposal.sponsor);
        emit ProcessWhitelistProposal(proposalIndex, proposalId, didPass);
    }

    function processGuildKickProposal(uint256 proposalIndex) public {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal memory proposal = proposals[proposalId];
        ProposalMutable storage s = pState[proposalId];
        require(proposal.action == ProposalAction.GuildKick, "must be a guild kick proposal");
        s.state = ProposalState.Processed; // processed
        bool didPass = _didPass(proposalIndex);
        if (didPass) {
            s.state = ProposalState.Passed; // didPass
            Member storage member = members[proposal.applicant];
            member.jailed = proposalIndex;
            // transfer shares to loot
            member.loot = member.loot + member.shares;
            totals.totalShares = totals.totalShares - member.shares;
            totals.totalLoot = totals.totalLoot + member.shares;
            member.shares = 0; // revoke all shares
        }
        proposedToKick[proposal.applicant] = false;
        _returnDeposit(proposal.sponsor);
        emit ProcessGuildKickProposal(proposalIndex, proposalId, didPass);
    }

    function _didPass(uint256 proposalIndex) internal view returns (bool didPass) {
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];
        ProposalMutable memory s = pState[proposalQueue[proposalIndex]];
        didPass = s.yesVotes > s.noVotes;
        // Make the proposal fail if the dilutionBound is exceeded
        if ((totals.totalShares + (totals.totalLoot)) * (dilutionBound) < s.maxTotalSharesAndLootAtYesVote) {
            didPass = false;
        }
        // Make the proposal fail if the applicant is jailed
        // - for standard proposals, we don't want the applicant to get any shares/loot/payment
        // - for guild kick proposals, we should never be able to propose to kick a jailed member (or have two kick proposals active), so it doesn't matter
        if (members[proposal.applicant].jailed != 0) {
            didPass = false;
        }

        return didPass;
    }

    function _validateProposalForProcessing(uint256 proposalIndex) internal view {
        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];
        ProposalMutable memory s = pState[proposalQueue[proposalIndex]];
        require(getCurrentPeriod() >= proposal.startingPeriod +
            votingPeriodLength + gracePeriodLength,
            "proposal is not ready to be processed"
        );
        require(s.state != ProposalState.Processed, "proposal has already been processed");
        require(
            proposalIndex == 0 ||
            pState[proposalQueue[proposalIndex-1]].state == ProposalState.Processed,
            "previous proposal must be processed"
        );
    }

    function _returnDeposit(address sponsor) internal {
        unsafeInternalTransfer(ESCROW, msg.sender, depositToken, processingReward);
        unsafeInternalTransfer(ESCROW, sponsor, depositToken, proposalDeposit - processingReward);
    }

    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external onlyMember {
        _ragequit(msg.sender, sharesToBurn, lootToBurn);
    }

    function _ragequit(address memberAddress, uint256 sharesToBurn, uint256 lootToBurn) internal {
        uint256 initialTotalSharesAndLoot = totals.totalShares + totals.totalLoot;
        Member storage member = members[memberAddress];
        require(member.shares >= sharesToBurn, "insufficient shares");
        require(member.loot >= lootToBurn, "insufficient loot");
        require(canRagequit(member.highestIndexYesVote), "cannot ragequit until highest index proposal member voted YES on is processed");
        uint256 sharesAndLootToBurn = sharesToBurn + lootToBurn;
        // burn shares and loot
        member.shares = member.shares - sharesToBurn;
        member.loot = member.loot - lootToBurn;
        totals.totalShares = totals.totalShares - sharesToBurn;
        totals.totalLoot = totals.totalLoot - lootToBurn;
        for (uint256 i = 0; i < approvedTokens.length; i++) {
            uint256 amountToRagequit = fairShare(userTokenBalances[GUILD][approvedTokens[i]], sharesAndLootToBurn, initialTotalSharesAndLoot);
            if (amountToRagequit > 0) { // gas optimization to allow a higher maximum token limit
                // deliberately not using safemath here to keep overflows from preventing the function execution (which would break ragekicks)
                // if a token overflows, it is because the supply was artificially inflated to oblivion, so we probably don't care about it anyways
                unchecked {
                    userTokenBalances[GUILD][approvedTokens[i]] -= amountToRagequit;
                    userTokenBalances[memberAddress][approvedTokens[i]] += amountToRagequit;
                }
            }
        }
        emit Ragequit(msg.sender, sharesToBurn, lootToBurn);
    }

    function ragekick(address memberToKick) public {
        Member storage member = members[memberToKick];
        require(member.jailed != 0, "member must be in jail");
        require(member.loot > 0, "member must have some loot"); // note - should be impossible for jailed member to have shares
        require(canRagequit(member.highestIndexYesVote), "cannot ragequit until highest index proposal member voted YES on is processed");
        _ragequit(memberToKick, 0, member.loot);
    }

    function withdrawBalance(address _token, uint256 _amount) public {
        _withdrawBalance(_token, _amount);
    }

    function withdrawBalances(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bool _max) public
    {
        require(_tokens.length == _amounts.length, "tokens and amounts arrays must be matching lengths");
        for (uint256 i=0; i < _tokens.length; i++) {
            uint256 withdrawAmount = _amounts[i];
            if (_max) { // withdraw the maximum balance
                withdrawAmount = userTokenBalances[msg.sender][_tokens[i]];
            }
            _withdrawBalance(_tokens[i], withdrawAmount);
        }
    }

    function _withdrawBalance(address token, uint256 amount) internal {
        require(userTokenBalances[msg.sender][token] >= amount, "insufficient balance");
        unsafeSubtractFromBalance(msg.sender, token, amount);
        require(IERC20(token).transfer(msg.sender, amount), "transfer failed");
        emit Withdraw(msg.sender, token, amount);
    }

    function collectTokens(address token) public onlyDelegate {
        uint256 amountToCollect = IERC20(token).balanceOf(address(this)) - userTokenBalances[TOTAL][token];
        // only collect if 1) there are tokens to collect 2) token is whitelisted 3) token has non-zero balance
        require(amountToCollect > 0, 'no tokens to collect');
        require(tokenWhitelist[token], 'token to collect must be whitelisted');
        require(userTokenBalances[GUILD][token] > 0, 'token to collect must have non-zero guild bank balance');
        unsafeAddToBalance(GUILD, token, amountToCollect);
        emit TokensCollected(token, amountToCollect);
    }

    // NOTE: requires that delegate key which sent the original proposal cancels, msg.sender == proposal.proposer
    function cancelProposal(uint256 proposalId) external {
        Proposal memory proposal = proposals[proposalId];
        ProposalMutable storage s = pState[proposalId];
        //require(s.state != ProposalState.Sponsored, "proposal has already been sponsored");
        //require(s.state != ProposalState.Cancelled, "proposal has already been cancelled");
        require(s.state == ProposalState.Proposed, "must be in Proposed state");
        require(msg.sender == proposal.proposer, "solely the proposer can cancel");
        s.state = ProposalState.Cancelled; // cancelled
        unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);
        emit CancelProposal(proposalId, msg.sender);
    }

    function updateDelegateKey(address newDelegateKey) external onlyShareholder {
        require(newDelegateKey != address(0), "newDelegateKey cannot be 0");
        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(!members[newDelegateKey].exists, "cannot overwrite existing members");
            require(!members[memberAddressByDelegateKey[newDelegateKey]].exists, "cannot overwrite existing delegate keys");
        }
        Member storage member = members[msg.sender];
        memberAddressByDelegateKey[member.delegateKey] = address(0);
        memberAddressByDelegateKey[newDelegateKey] = msg.sender;
        member.delegateKey = newDelegateKey;
        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }

    // can only ragequit if the latest proposal you voted YES on has been processed
    function canRagequit(uint256 highestIndexYesVote) public view returns (bool) {
        require(highestIndexYesVote < proposalQueue.length, "proposal does not exist");
        return pState[proposalQueue[highestIndexYesVote]].state == ProposalState.Processed;
    }

    function hasVotingPeriodExpired(uint256 startingPeriod) public view returns (bool) {
        return getCurrentPeriod() >= startingPeriod + votingPeriodLength;
    }

    /***************
    GETTER FUNCTIONS
    ***************/

    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }

    function getCurrentPeriod() public view returns (uint256) {
        return (block.timestamp - summoningTime) / periodDuration;
    }

    function getProposalQueueLength() public view returns (uint256) {
        return proposalQueue.length;
    }

    function getUserTokenBalance(address user, address token) public view returns (uint256) {
        return userTokenBalances[user][token];
    }

    function getMemberProposalVote(address memberAddress, uint256 proposalIndex) public view returns (Vote) {
        require(members[memberAddress].exists, "member does not exist");
        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        return  votesByMember[memberAddress][proposalIndex];
    }

    function getTokenCount() public view returns (uint256) {
        return approvedTokens.length;
    }

    /***************
    HELPER FUNCTIONS
    ***************/
    function unsafeAddToBalance(address user, address token, uint256 amount) internal {
        unchecked {
            userTokenBalances[user][token] += amount;
            userTokenBalances[TOTAL][token] += amount;
        }

    }

    function unsafeSubtractFromBalance(address user, address token, uint256 amount) internal {
        unchecked {
            userTokenBalances[user][token] -= amount;
            userTokenBalances[TOTAL][token] -= amount;
        }

    }

    function unsafeInternalTransfer(address from, address to, address token, uint256 amount) internal {
        unsafeSubtractFromBalance(from, token, amount);
        unsafeAddToBalance(to, token, amount);
    }

    function fairShare(uint256 balance, uint256 shares, uint256 totalShares) internal pure returns (uint256) {
        require(totalShares != 0);
        if (balance == 0) { return 0; }
        //uint256 prod = balance * shares;
        //if (prod / balance == shares) { // no overflow in multiplication above? (solidity 0.8 checks this)
        //    return prod / totalShares;
        //}
        return (balance / totalShares) * shares;
    }
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}