pragma solidity 0.4.18;


/// @title Fund Wallet - Fund raising and distribution wallet according to stake and incentive scheme.
/// @dev Not fully tested, use only in test environment.
contract FundWallet {

    //storage
    address public admin;
    address public backupAdmin;
    uint public adminStake;
    uint public balance;
    uint public endBalance;
    bool public adminStaked;
    bool public endBalanceLogged;
    mapping (address => bool) public isContributor;
    mapping (address => bool) public hasClaimed;
    mapping (address => uint) public stake;
    address[] public contributors;
    //experimental time periods
    uint start;
    uint raiseP;
    uint opperateP;
    uint liquidP;
    //admin operational withdrawal
    uint public lastDay;
    uint public withdrawnToday;
    //admin reward
    uint adminCarry; //in basis points (1% = 100bps)

    //modifiers
    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    modifier onlyBackupAdmin() {
        require(msg.sender == backupAdmin);
        _;
    }

    modifier onlyContributor() {
        require(isContributor[msg.sender]);
        _;
    }

    modifier adminHasStaked() {
        assert(adminStaked == true);
        _;
    }

    modifier adminHasNotStaked() {
        assert(adminStaked == false);
        _;
    }

    modifier endBalanceNotLogged() {
        assert(endBalanceLogged == false);
        _;
    }

    modifier endBalanceIsLogged() {
        assert(endBalanceLogged == true);
        _;
    }

    modifier hasNotClaimed() {
        require(!hasClaimed[msg.sender]);
        _;
    }

    modifier inRaiseP() {
        require(now < (start + raiseP));
        _;
    }

    modifier inOpperateP() {
        require(now < (start + raiseP + opperateP) && now > (start + raiseP));
        _;
    }

    modifier inLiquidP() {
        require(now < (start + raiseP + opperateP + liquidP) && now > (start + raiseP + opperateP));
        _;
    }

    modifier inClaimP() {
        require(now > (start + raiseP + opperateP + liquidP));
        _;
    }

    //events
    event ContributorAdded(address _contributor);
    event ContributorRemoval(address _contributor);
    event ContributorDeposit(address sender, uint value);
    event ContributorDepositReturn(address _contributor, uint value);
    event AdminDeposit(address sender, uint value);
    event AdminDepositReturned(address sender, uint value);


    /// @notice Constructor, initialises wallet with admins, time periods, stake and incentive scheme.
    /// @dev Should break constructor up into a few components.
    /// @param _admin Is main opperator address.
    /// @param _backupAdmin Is an address which can change the admin address - recommend cold wallet.
    /// @param _adminStake Is the amount that the admin will contribute to the fund.
    /// @param _raiseP The amount of time during which contributors and admin can contribute to the fund. In minutes for testing.
    /// @param _opperateP The amount of time during which the fund is actively trading/investing. In minutes for testing.
    /// @param _liquidP The amount of time the admin has to liquidate the fund into base currency - Ether. In minutes for testing.
    /// @param _adminCarry The admins performance fee in profitable scenario, measured in basis points (1% = 100bps).
    function FundWallet(address _admin, address _backupAdmin, uint _adminStake, uint _raiseP, uint _opperateP, uint _liquidP, uint _adminCarry) public {
        require(_admin != address(0));
        require(_adminStake > 0);
        admin = _admin;
        backupAdmin = _backupAdmin;
        adminStake = _adminStake;
        start = now;
        raiseP = _raiseP * (60 seconds);
        opperateP = _opperateP * (60 seconds);
        liquidP = _liquidP * (60 seconds);
        adminCarry = _adminCarry; //bps
    }

    /// @notice Fallback function - recieves ETH but doesn't alter contributor stakes or raised balance.
    function() public payable {
    }

    /// @notice Function to change the admins address
    /// @dev Only available to the back up admin.
    /// @param _newAdmin address of the new admin.
    function changeAdmin(address _newAdmin) public onlyBackupAdmin {
        admin = _newAdmin;
    }

    /// @notice Function to add contributor address.
    /// @dev Only available to admin and in the raising period.
    /// @param _contributor Address of the new contributor.
    function addContributor(address _contributor) public onlyAdmin inRaiseP {
        require(!isContributor[ _contributor]); //only new contributor
        require(_contributor != admin);
        isContributor[ _contributor] = true;
        contributors.push( _contributor);
        ContributorAdded( _contributor);
    }

    /// @notice Function to remove contributor address.
    /// @dev Only available to admin and in the raising period. Returns balance of contributor if they have deposited.
    /// @param _contributor Address of the contributor to be removed.
    function removeContributor(address _contributor) public onlyAdmin inRaiseP {
        require(isContributor[_contributor]);
        isContributor[_contributor] = false;
        for (uint i=0; i < contributors.length - 1; i++)
            if (contributors[i] == _contributor) {
                contributors[i] = contributors[contributors.length - 1];
                break;
            }
        contributors.length -= 1;
        ContributorRemoval(_contributor);

        if (stake[_contributor] > 0) {
            _contributor.transfer(stake[_contributor]);
            balance -= stake[_contributor];
            delete stake[_contributor];
            ContributorDepositReturn(_contributor, stake[_contributor]);
        }
    }
    
    /// @notice Function to get contributor addresses.
    function getContributors() public constant returns (address[]){
        return contributors;
    }
    
    /// @notice Function for contributor to deposit funds.
    /// @dev Only available to contributors after admin had deposited their stake, and in the raising period.
    function contributorDeposit() public onlyContributor adminHasStaked inRaiseP payable {
        if (adminStake >= msg.value && msg.value > 0 && stake[msg.sender] < adminStake) {
            balance += msg.value;
            stake[msg.sender] += msg.value;
            ContributorDeposit(msg.sender, msg.value);
        }
        else {
            revert();
        }
    }
    
    /// @notice Function for contributor to reclaim their deposit.
    /// @dev Only available to contributor in the raising period. Removes contributor on refund.
    function contributorRefund() public onlyContributor inRaiseP {
        isContributor[msg.sender] = false;
        for (uint i=0; i < contributors.length - 1; i++)
            if (contributors[i] == msg.sender) {
                contributors[i] = contributors[contributors.length - 1];
                break;
            }
        contributors.length -= 1;
        ContributorRemoval(msg.sender);

        if (stake[msg.sender] > 0) {
            msg.sender.transfer(stake[msg.sender]);
            balance -= stake[msg.sender];
            delete stake[msg.sender];
            ContributorDepositReturn(msg.sender, stake[msg.sender]);
        }
    }

    /// @notice Function for admin to deposit their stake.
    /// @dev Only available to admin and in the raising period.
    function adminDeposit() public onlyAdmin adminHasNotStaked inRaiseP payable {
        if (msg.value == adminStake) {
            balance += msg.value;
            stake[msg.sender] += msg.value;
            adminStaked = true;
            AdminDeposit(msg.sender, msg.value);
        }
        else {
            revert();
        }
    }
    
    /// @notice Funtion for admin to reclaim their contribution/stake.
    /// @dev Only available to admin and in the raising period and if admin is the only one who has contributed to the fund.
    function adminRefund() public onlyAdmin adminHasStaked inRaiseP {
        require(balance == adminStake);
        admin.transfer(adminStake);
        adminStaked = false;
        balance -= adminStake;
        AdminDepositReturned(msg.sender, adminStake);
    }
    
    /// @notice Funtion for admin to withdraw funds whild fund is opperating.
    /// @dev Only available to admin and in the opperating period, and limited by their stake in 24hr period.
    /// @param _amount Funds to withdraw.
    function opsWithdraw(uint _amount) public onlyAdmin inOpperateP {
        assert(isUnderLimit(_amount));
        admin.transfer(_amount);
        withdrawnToday += _amount;
    }

    /// @notice Internal function to check that withdrawal is below admin stake in 24hrs.
    function isUnderLimit(uint amount) internal returns (bool) {
        if (now > lastDay + 24 hours) {
            lastDay = now;
            withdrawnToday = 0;
        }
        if (withdrawnToday + amount > adminStake || withdrawnToday + amount < withdrawnToday)
            return false;
        return true;
    }
    
    /// @notice Funtion to check remaining withdrawal balance of admin.
    function calcMaxOpsWithdraw() public constant returns (uint)  {
        if (now > lastDay + 24 hours)
            return adminStake;
        if (adminStake < withdrawnToday)
            return 0;
        return adminStake - withdrawnToday;
    }

    /// @notice Funtion to log the ending balance after liquidation period. Used as point of reference to calculate profit/loss.
    /// @dev Only available in claim period and only available once.
    function logEndBal() public inClaimP endBalanceNotLogged {
        endBalance = address(this).balance;
        endBalanceLogged = true;
    }

    /// @notice Funtion for admin to calim their payout.
    /// @dev Only available to admin in claim period and once the ending balance has been logged. Payout depends on profit or loss.
    function adminClaim() public onlyAdmin inClaimP endBalanceIsLogged hasNotClaimed {
        if (endBalance > balance) {
            admin.transfer(((endBalance - balance)*(adminCarry))/10000); //have variable for adminReward
            admin.transfer(((((endBalance - balance)*(10000-adminCarry))/10000)*adminStake)/balance); // profit share
            admin.transfer(adminStake); //initial stake
            hasClaimed[msg.sender] = true;
        }
        else {
            admin.transfer((endBalance*adminStake)/balance);
            hasClaimed[msg.sender] = true;
        }
    }

    /// @notice Funtion for contributor to claim their payout.
    /// @dev Only available to contributor in claim period and once the ending balance has been logged. Payout depends on profit or loss.
    function contributorClaim() public onlyContributor inClaimP endBalanceIsLogged hasNotClaimed {
        if (endBalance > balance) {
            msg.sender.transfer(((((endBalance - balance)*(10000-adminCarry))/10000)*stake[msg.sender])/balance); // profit share
            msg.sender.transfer(stake[msg.sender]); //initial stake
            hasClaimed[msg.sender] = true;
        }
        else {
            msg.sender.transfer((endBalance*stake[msg.sender])/balance);
            hasClaimed[msg.sender] = true;
        }
    }

}
