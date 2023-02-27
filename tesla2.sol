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
    uint public price;
    uint public minUnits = 1;
    uint public maxUnits = 2;
    uint public dailyLimit = 1000;
    uint public totalDeposit;
    uint public totalBonus;
    uint public totalAllocated;
    uint public totalWithdrawn;
    uint public totalCommission;
    uint public nextPayIndex;
    uint public payMultiplier = 2;
    uint public totalUsers;

    Counters.Counter private _dailyLimit;

    uint[] private commRate = [70, 40, 30, 20]; //referrals commission rate
    uint[] private sameRankCommRate = [0, 5, 5, 10]; //same rank commission rate
    uint private commFeeRate = 180; //total commission should be payout
    uint private companyFee = 150; //company earning
    uint private poolRate = 20; //for sharing prize pool
    uint private marketingFee = 150; //for marketing purpose
    uint private levelStep = 5;
    uint private MAX_LEVEL = 4;

    uint private available;

    address private companyWallet = 0x7132aDC062d1a02bB13Aa650a5475252955fe373;
    address private marketingWallet = 0x7132aDC062d1a02bB13Aa650a5475252955fe373;
    address private poolWallet = 0x7132aDC062d1a02bB13Aa650a5475252955fe373;

    bool private started = false;

    struct Deposit {
        address account;
        uint amount;
        uint payout;
        uint allocated;
        uint bonus;
        bool paid;
        uint checkpoint;
    }

    struct User {
        address referer;
        address account;
        uint[] deposits;
        uint[] partners;
        uint totalDeposit;
        uint totalAllocated;
        uint totalWithdrawn;
        bool disableDeposit;
        bool activate;
        bool autoReinvest;
        uint totalBonus;
        uint directBonus;
    }

    struct Level {
        uint level;
        uint[6] uplineCount;
    }

    Deposit[] private deposits;
    mapping(address => uint) private userids;
    mapping(uint => User) private users;
    mapping(uint => Level) private levels;
    mapping(uint => uint) private checkpoints;

    event Commission(uint value);
    event UserMsg(uint userid, string msg, uint value);

    constructor(IERC20 _token, uint _price) {
        token = _token;
        price = _price;
    }

    receive() external payable {}

    function withdraw() external onlyOwner {
        if (address(this).balance > 0) {
            payable(companyWallet).transfer(address(this).balance);
        }
        if (token.balanceOf(address(this)) > 0) {
            token.safeTransfer(companyWallet, token.balanceOf(address(this)));
        }
    }

    function invest(address referer, uint units) external {
        require(started, "Investment program haven't start!");
        require(units >= minUnits && units <= maxUnits, "Invalid units");
        require(_dailyLimit.current() <= dailyLimit, "Over Daily Limit");
        
        _dailyLimit.increment();
        processDeposit(referer, units);
        payReferral(referer, units);
        payQueue();
    }

    function processDeposit(address referer, uint units) private {
        uint userid = userids[msg.sender];
        if (userid == 0) {
            totalUsers++;
            userid = totalUsers;
            userids[msg.sender] = userid;
            checkpoints[userid] = block.timestamp;
            emit UserMsg(userid, "Joined", 0);
        }

        User storage user = users[userid];
        require(!user.disableDeposit, "Pending Withdraws");
        user.disableDeposit = true;
        user.activate = true;
        user.autoReinvest = true;

        if (user.referer == address(0) && users[userids[referer]].deposits.length > 0 && referer != msg.sender) {
            user.referer = referer;
            users[userids[referer]].partners.push(userid);
            processLevelUpdate(referer, msg.sender);
        }

        uint value = units * price;
        token.safeTransferFrom(msg.sender, address(this), value);
        totalDeposit += value;

        Deposit memory deposit = Deposit({
            account: msg.sender,
            amount: value,
            payout: 0,
            allocated: 0,
            bonus: 0,
            paid: false,
            checkpoint: block.timestamp
        });

        emit UserMsg(userids[msg.sender], "Deposit", value);

        user.deposits.push(deposits.length);
        deposits.push(deposit);
        user.totalDeposit += value;
        available += value;
    }

    function payReferral(address referer, uint units) private returns (uint){
        uint value = price * units;
        uint currTotalCommission = value * commFeeRate / 1000;
        uint remainingCommission = currTotalCommission;
        uint totalRefOut;
        uint prevUplineLevel = 0;
        bool sameRankClaimed = false;
 
        address upline = referer;

        for(uint i = 0; i < 4; i++) {
            User storage user = users[userids[referer]];
            uint uplineId = userids[upline];
            uint currUplineLevel = levels[uplineId].level;
            User storage currUplineUser = users[uplineId];

            if (uplineId == 0 || upline == address(0) || currUplineLevel < prevUplineLevel || user.activate == false) break;
            
            uint commission;

            if(currUplineLevel >= prevUplineLevel) {
                uint accruedRate = getAccruedReferralRate(prevUplineLevel, currUplineLevel);
                if(accruedRate > 0) {
                    commission = value * accruedRate / 1000;
                    performTransfer(upline, uplineId, commission);
                    totalRefOut = totalRefOut + commission;
                    remainingCommission = remainingCommission - commission;
                    if (i == 0)
                        users[uplineId].directBonus += commission;
                }
                sameRankClaimed = false;
            }
            else if(currUplineLevel == prevUplineLevel && !sameRankClaimed && currUplineLevel > 0) {
                uint sameRankRate = sameRankCommRate[currUplineLevel - 1];
                if (sameRankRate > 0) {
                    commission = value * sameRankCommRate[i] / 1000;
                    performTransfer(upline, uplineId, commission);
                    totalRefOut = totalRefOut + commission;
                    remainingCommission = remainingCommission - commission;
                    if (i == 0)
                        currUplineUser.directBonus += commission;
                    sameRankClaimed = true;
                }

                i--;
            }
            upline = currUplineUser.referer;
            prevUplineLevel = currUplineLevel;
        }

        if (remainingCommission > 0) {
            token.safeTransfer(companyWallet, remainingCommission);
        }

        totalBonus += totalRefOut;
        totalCommission += currTotalCommission;
        available -= currTotalCommission;
        uint companyOut = value * companyFee / 1000;
        token.safeTransfer(companyWallet, companyOut);
        uint marketingOut = value * marketingFee / 1000;
        token.safeTransfer(marketingWallet, marketingOut);
        uint poolOut = value * poolRate / 1000;
        token.safeTransfer(poolWallet, poolOut);
        uint commi = companyOut + marketingOut + poolOut;
        emit Commission(commi);
        available -= commi;
        return commi;
    }

    function performTransfer(address referer, uint uplineId, uint amount) private {
        token.safeTransfer(referer, amount);
        emit UserMsg(uplineId, "RefBonus", amount);
    }

    function getAccruedReferralRate(uint prevLevel, uint currLevel) private view returns (uint) {
        if (prevLevel >= currLevel || currLevel > MAX_LEVEL) {
            return 0;
        }

        uint rateSum;
        for (uint i = prevLevel; i < currLevel; i++) {
            rateSum += commRate[i];
        }
        return rateSum;
    }

    function processLevelUpdate(address referer, address from) private {
        uint refererid = userids[referer];
        uint fromid = userids[from];
        if (referer == address(0) && refererid == 0) return;
        User storage user = users[refererid];
        Level storage level = levels[refererid];
        uint fromLevel = levels[fromid].level;
        uint newLevel = level.level;

        if (fromLevel == 0) {
            level.uplineCount[0]++;
            if (level.uplineCount[0] >= levelStep && newLevel < 1) {
                level.level = 1;
                emit UserMsg(refererid, "LevelUp", 1);
                processLevelUpdate(user.referer, referer);
            }
        } else if (fromLevel == 1 && level.uplineCount[1] < levelStep - 1) {
            level.uplineCount[1]++;
            if (level.uplineCount[1] >= levelStep - 1 && newLevel < 2) {
                level.level = 2;
                emit UserMsg(refererid, "LevelUp", 2);
                processLevelUpdate(user.referer, referer);
            }
        } else if (fromLevel == 2 && level.uplineCount[2] < levelStep - 2) {
            level.uplineCount[2]++;
            if (level.uplineCount[2] >= levelStep - 2 && newLevel < 3) {
                level.level = 3;
                emit UserMsg(refererid, "LevelUp", 3);
                processLevelUpdate(user.referer, referer);
            }
        } else if (fromLevel == 3 && level.uplineCount[3] < levelStep - 2) {
            level.uplineCount[3]++;
            if (level.uplineCount[3] >= levelStep - 2 && newLevel < 4) {
                level.level = 4;
                emit UserMsg(refererid, "LevelUp", 4);
                processLevelUpdate(user.referer, referer);
            }
        } else if (fromLevel == 4) {
            level.uplineCount[4]++;
            if (level.uplineCount[4] >= levelStep && newLevel < 5) {
                level.level = 5;
                emit UserMsg(refererid, "LevelUp", 5);
                processLevelUpdate(user.referer, referer);
            }
        }
    }

    function payQueue() private {
        for (uint index = nextPayIndex; index < deposits.length - 1; index++) {
            Deposit storage deposit = deposits[index];
            uint balance = token.balanceOf(address(this));
            User storage user = users[userids[deposit.account]];
            uint half = available * 8 / 10;
            uint needPay = deposit.amount * payMultiplier - deposit.allocated;
            if (needPay == 0) continue;
            if (half >= needPay) {
                if (balance < needPay) return;
                available -= needPay;
                deposit.allocated += needPay;
                deposit.paid = true;
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
        uint shareUsers = totalUsers - 1;
        uint share = available;
        if (share == 0) return;
        for (uint index = nextPayIndex; index < deposits.length - 1; index++) {
            Deposit storage deposit = deposits[index];
            uint needPay = deposit.amount * payMultiplier - deposit.allocated;
            uint balance = token.balanceOf(address(this));
            if (needPay == 0) continue;
            User storage user = users[userids[deposit.account]];
            uint topay = share / shareUsers;
            if (topay >= needPay) {
                if (balance < needPay) return;
                if (available < needPay) return;
                token.safeTransfer(deposit.account, needPay);
                available -= needPay;
                deposit.allocated = deposit.allocated + needPay;
                deposit.paid = true;
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

    function reInvest() private {
        User storage user = users[userids[msg.sender]];
        require(user.deposits.length > 0, "User has no deposits");
        require(user.autoReinvest == true, "Auto invest is on!");

        for (uint i = 0; i < user.deposits.length; i++) {
            Deposit storage deposit = deposits[user.deposits[i]];
            if (deposit.allocated == deposit.amount * 2) {
                uint reinvestAmount = price * maxUnits;
                deposit.allocated = deposit.amount + reinvestAmount;
                available -= reinvestAmount;
                user.totalDeposit += reinvestAmount;
                user.disableDeposit = true;
                emit UserMsg(userids[msg.sender], "Reinvest", reinvestAmount);
                processDeposit(msg.sender, reinvestAmount);
                break;
            }
        }
    }

    function claim() external {
        User storage user = users[userids[msg.sender]];
        require(user.deposits.length > 0, "User has no deposits");

        uint totalPayout;
        for (uint i = 0; i < user.deposits.length; i++) {
            Deposit storage deposit = deposits[user.deposits[i]];
            if (deposit.allocated > deposit.payout) {
                uint payoutAmount = deposit.allocated - deposit.payout;
                deposit.payout += payoutAmount;
                user.totalWithdrawn += payoutAmount;
                totalWithdrawn += payoutAmount;
                totalPayout += payoutAmount;
            }

            if (deposit.allocated == deposit.payout) {
                user.activate = false;
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

    function setDailyLimit(uint _dayLimit) external onlyOwner {
        dailyLimit = _dayLimit;
    }

    function setLevel(uint userid, uint level) external onlyOwner {   
        levels[userid].level = level;
    }

    function setStarted() external onlyOwner {
        started = true;
    }

    function setPause() external onlyOwner {
        started = false;
    }

    function setPrice(uint _price) external onlyOwner {
        price = _price;
    }

    function setToken(IERC20 _token) external onlyOwner {
        token = _token;
    }

    function setMaxUnits(uint units) external onlyOwner {
        maxUnits = units;
    }

    function setCompanyWallet(address wallet) external onlyOwner {
        companyWallet = wallet;
    }

    function setCommRate(uint256[] memory rates) external onlyOwner {
        commRate = rates;
    }

    function setSRankRate(uint256[] memory rates) external onlyOwner {
        sameRankCommRate = rates;
    }

    function setPayMultiplier(uint multiplier) external onlyOwner {
        payMultiplier = multiplier;
    }

    function getDeposits(uint[] calldata indexs) external view returns (Deposit[] memory) {
        Deposit[] memory deps = new Deposit[](indexs.length);
        for (uint i = 0; i < indexs.length; i++) {
            deps[i] = deposits[indexs[i]];
        }
        return deps;
    }

    function userDeposits(address account) public view returns (Deposit[] memory) {
        uint[] memory depositIndexs = users[userids[account]].deposits;
        Deposit[] memory deps = new Deposit[](depositIndexs.length);
        for (uint i = 0; i < depositIndexs.length; i++) {
            deps[i] = deposits[depositIndexs[i]];
        }
        return deps;
    }

    function userInfoById(uint id) public view returns(uint, uint, User memory, Level memory) {
        User storage user = users[id];
        Level storage level = levels[id];
        return (id, userids[user.referer], user, level);
    }

    function userInfoByAddress(address account) public view returns(uint, uint, User memory, Level memory) {
        uint userid = userids[account];
        return userInfoById(userid);
    }

    function partnerIdsById(uint id) public view returns (uint[] memory){
        User storage user = users[id];
        return user.partners;
    }

    function contractInfo() public view returns (uint, uint, uint, uint, uint, uint, uint, uint) {
        return (
            totalDeposit, 
            totalBonus,
            totalWithdrawn, 
            deposits.length, 
            totalUsers, 
            price, 
            maxUnits, 
            nextPayIndex
        );
    }

    function userInfo(uint userId) public view returns (address, uint, address, uint, uint, uint, uint, uint, uint) {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User memory user = users[userId];

        return (
            user.referer,
            userids[user.referer],
            user.account, 
            user.partners.length,
            user.totalDeposit,
            user.totalAllocated,
            user.totalWithdrawn,
            user.totalBonus,
            user.directBonus
        );
    }
}
