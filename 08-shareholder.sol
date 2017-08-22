pragma solidity ^0.4.2;

contract owned {
    address public owner;

    function owned() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require (msg.sender == owner);
        _;
    }

    function transferOwnership(address newOwner) onlyOwner {
        owner = newOwner;
    }
}

contract tokenRecipient {
    event receivedEther(address sender, uint amount);
    event receivedTokens(address _from, uint256 _value, address _token, bytes _extraData);

    function receiveApproval(address _from, uint256 _value, address _token, bytes _extraData){
        Token t = Token(_token);
        require (!t.transferFrom(_from, this, _value));
        receivedTokens(_from, _value, _token, _extraData);
    }

    function () payable {
        receivedEther(msg.sender, msg.value);
    }
}

contract Token {
    mapping (address => uint256) public balanceOf;
    function transferFrom(address _from, address _to, uint256 _value) returns (bool success);
}

/* The shareholder association contract itself */

contract Association is owned, tokenRecipient {

    /* Contract Variables and events */
    uint public minimumQuorum;
    uint public debatingPeriodInMinutes;
    Proposal[] public proposals;
    uint public numProposals;
    Token public sharesTokenAddress;

    event ProposalAdded(uint proposalID, address recipient, uint amount, string description);
    event Voted(uint proposalID, bool position, address voter);
    event ProposalTallied(uint proposalID, uint result, uint quorum, bool active);
    event ChangeOfRules(uint newMinimumQuorum, uint newDebatingPeriodInMinutes, address newSharesTokenAddress);


    struct Proposal {
        address recipient;
        uint amount;
        string description;
        uint votingDeadline;
        bool executed;
        bool proposalPassed;
        uint numberOfVotes;
        bytes32 proposalHash;
        Vote[] votes;
        mapping (address => bool) voted;
    }

    struct Vote {
        bool inSupport;
        address voter;
    }

    /* modifier that allows only shareholders to vote and create new proposals */
    modifier onlyShareholders {
        require (sharesTokenAddress.balanceOf(msg.sender) > 0);
        _;
    }

    /* First time setup */
    function Association(Token sharesAddress, uint minimumSharesToPassAVote, uint minutesForDebate) payable {
        changeVotingRules(sharesAddress, minimumSharesToPassAVote, minutesForDebate);
    }

    /// @notice Make so that proposals need tobe discussed for at least `minutesForDebate/60` hours and all voters combined must own more than `minimumSharesToPassAVote` shares of token `sharesAddress` to be executed
    /// @param sharesAddress token address
    /// @param minimumSharesToPassAVote proposal can vote only if the sum of shares held by all voters exceed this number      
    /// @param minutesForDebate the minimum amount of delay between when a proposal is made and when it can be executed    
    function changeVotingRules(Token sharesAddress, uint minimumSharesToPassAVote, uint minutesForDebate) onlyOwner {
        sharesTokenAddress = Token(sharesAddress);
        if (minimumSharesToPassAVote == 0 ) minimumSharesToPassAVote = 1;
        minimumQuorum = minimumSharesToPassAVote;
        debatingPeriodInMinutes = minutesForDebate;
        ChangeOfRules(minimumQuorum, debatingPeriodInMinutes, sharesTokenAddress);
    }

    /// @notice Propose to send `weiAmount / 1E18` ether to `beneficiary` for `JobDescription`. `transactionBytecode ? Contains : Does not contain` code.
    /// @param beneficiary who to send the ether to      
    /// @param weiAmount amount of ether to send, in wei       
    /// @param JobDescription Description of job
    /// @param transactionBytecode bytecode of transaction
    function newProposal(
        address beneficiary,
        uint weiAmount,
        string JobDescription,
        bytes transactionBytecode
    )
        onlyShareholders
        returns (uint proposalID)
    {
        proposalID = proposals.length++;
        Proposal storage p = proposals[proposalID];
        p.recipient = beneficiary;
        p.amount = weiAmount;
        p.description = JobDescription;
        p.proposalHash = sha3(beneficiary, weiAmount, transactionBytecode);

        p.votingDeadline = now + debatingPeriodInMinutes * 1 minutes;
        p.executed = false;
        p.proposalPassed = false;
        p.numberOfVotes = 0;
        ProposalAdded(proposalID, beneficiary, weiAmount, JobDescription);

        numProposals = proposalID+1;

        return proposalID;
    }

    /// @notice Propose to send `etherAmount` ether to `beneficiary` for `JobDescription`. `transactionBytecode ? Contains : Does not contain` code.
    /// @param beneficiary who to send the ether to      
    /// @param etherAmount amount of ether to send       
    /// @param JobDescription Description of job
    /// @param transactionBytecode bytecode of transaction
    function newProposalInEther(
        address beneficiary,
        uint etherAmount,
        string JobDescription,
        bytes transactionBytecode
    )
        onlyShareholders
        returns (uint proposalID)
    {
        return newProposal(beneficiary, etherAmount * 1 ether, JobDescription, transactionBytecode);
    }

    /* function to check if a proposal code matches */
    function checkProposalCode(
        uint proposalNumber,
        address beneficiary,
        uint weiAmount,
        bytes transactionBytecode
    )
        constant
        returns (bool codeChecksOut)
    {
        Proposal storage p = proposals[proposalNumber];
        return p.proposalHash == sha3(beneficiary, weiAmount, transactionBytecode);
    }

    /* */
    function vote(uint proposalNumber, bool supportsProposal)
        onlyShareholders
        returns (uint voteID)
    {
        Proposal p = proposals[proposalNumber];
        if (p.voted[msg.sender] == true) throw;

        voteID = p.votes.length++;
        p.votes[voteID] = Vote({inSupport: supportsProposal, voter: msg.sender});
        p.voted[msg.sender] = true;
        p.numberOfVotes = voteID +1;
        Voted(proposalNumber,  supportsProposal, msg.sender);
        return voteID;
    }

    function executeProposal(uint proposalNumber, bytes transactionBytecode) {
        Proposal storage p = proposals[proposalNumber];
        /* Check if the proposal can be executed */
        require (now > p.votingDeadline  /* has the voting deadline arrived? */
            &&  !p.executed        /* has it been already executed? */
            &&  p.proposalHash == sha3(p.recipient, p.amount, transactionBytecode)); /* Does the transaction code match the proposal? */


        /* tally the votes */
        uint quorum = 0;
        uint yea = 0;
        uint nay = 0;

        for (uint i = 0; i <  p.votes.length; ++i) {
            Vote storage v = p.votes[i];
            uint voteWeight = sharesTokenAddress.balanceOf(v.voter);
            quorum += voteWeight;
            if (v.inSupport) {
                yea += voteWeight;
            } else {
                nay += voteWeight;
            }
        }

        /* execute result */
        require (quorum <= minimumQuorum); /* Not enough significant voters */

        if (yea > nay ) {
            /* has quorum and was approved */
            p.executed = true;
            require (p.recipient.call.value(p.amount)(transactionBytecode));
            p.proposalPassed = true;
        } else {
            p.proposalPassed = false;
        }
        // Fire Events
        ProposalTallied(proposalNumber, yea - nay, quorum, p.proposalPassed);
    }
}