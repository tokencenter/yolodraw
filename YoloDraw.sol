//SPDX-License-Identifier: UNLICENSED

//    _||    __   __    ___      __       ___               ___      ___      ___   __      __
//   (_-<    \ \ / /   / _ \    | |      / _ \     ___     |   \    | _ \    /   \  \ \    / /
//   / _/     \ V /   | (_) |   | |__   | (_) |   |___|    | |) |   |   /    | - |   \ \/\/ /
//   _||__    _|_|_    \___/    |____|   \___/    _____    |___/    |_|_\    |_|_|    \_/\_/
// _|"""""| _| """ | _|"""""| _|"""""| _|"""""| _|     | _|"""""| _|"""""| _|"""""| _|"""""|
// "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-' "`-0-0-'


pragma solidity ^0.8.3;
//import "./SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.0.0-beta.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.0.0-beta.0/contracts/access/Ownable.sol";
interface ICakeIRouter {

    function getAmountsIn(uint amountOut, address[] memory path) external view returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] memory path)
    external
    view
    returns (uint256[] memory amounts);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface ICakeIFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2ERC20 {
    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);

    function sync() external;

    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}


interface ILPLock {
    function setLpToken(address lpTokenAdd) external;
}

contract YoloDraw is ERC20("YoloDraw", "YoloDraw"), Ownable {
    struct Participant {
        address id;
    }

    struct DividendParticipant {
        address id;
        uint minReq;
    }

    uint256 internal totalSupplyE = 1e26;
    uint256 internal fomoFund;
    uint internal devFund = 5e24;
    uint public forLiquidity;
    /* 1% */
    uint256 internal constant burnRate = 100;
    /* 10% then 4% */
    uint256 internal fomoTax = 10;
    uint256 internal lastRewardBlock;
    uint256 internal lastLPRewardBlock;

    // BSC-Add
    address public constant pRouter = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    address public constant CAKE_V2_FACTORY_ADDRESS = 0xBCfCcbde45cE874adCB698cC183deBcF17952812;
    address public constant WBNB_ADDRESS = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address public devLockContract;
    address public setterWallet;
    address payable public deployer;
    address[] internal path;
    address public FOMOV1_BNB_PAIR;
    address public LPLocker;

    ICakeIRouter  public  cakeRouter = ICakeIRouter(pRouter);
    ICakeIFactory  public  cakeFactory = ICakeIFactory(CAKE_V2_FACTORY_ADDRESS);

    /* Launch Metrics */
    uint public taxOnTransfer;
    uint public lpTaxOnTransfer;
    uint public lpRewardFund;
    uint internal minJoinDrawAmount = 2e17; //0.2BNB
    uint internal maxTxAmount = 3e17; //7.5 BNB
    uint256 internal minBNBforDiv = 4e18; // 4.0 BNB
    uint internal startBlockMaxTx;
    uint internal boostCounter;
    uint internal constant minParticipants = 3;
    uint internal constant numberOfWinners = 3;
    uint public gasRefund;

    DividendParticipant[] public currentDivParticipants;
    DividendParticipant[] public stillEligibleParticipants;
    Participant[] public currentParticipants;

    /* in block */
    uint256 internal cooldown = 600;
    bool public isSecondPhase = false;
    constructor() {
        path = [WBNB_ADDRESS, address(this)];
        lastRewardBlock = block.number;
        deployer = payable(msg.sender);
        boostCounter = 0;
        lpTaxOnTransfer = 50;
        super._mint(address(this), totalSupplyE);
        startBlockMaxTx = block.number;

        forLiquidity = 5e25;
        lpRewardFund = 5e24;
        /* 2% */
        
        fomoFund = forLiquidity / 2;

        super._burn(address(this), totalSupplyE - (fomoFund + forLiquidity + devFund + lpRewardFund));
        
        gasRefund = 3e21;
    }

    function transfer(address to, uint amount) public override returns (bool success){
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address sender, address to, uint amount) public override returns (bool success) {
        require(amount > 10000, "Broken: Cant send 0");

        /* Don't tax transfer from this add */
        if (sender == address(this)) {
            super._transfer(sender, to, amount);
            return true;
        }
        /* Don't tax on remove liq*/
        if ((sender == FOMOV1_BNB_PAIR && to == address(pRouter)) || sender == address(pRouter)){
            super._transfer(sender, to, amount);
            return true;
        }

        uint256 amtToBrun = amount / burnRate;
        // Apply Burn
        uint256 fomoTaxAmount = amount / fomoTax;
        uint256 lpRewardAmt = amount / lpTaxOnTransfer;
        // Apply FomoTax
        super._burn(sender, amtToBrun);
        /* TO FUND */
        super._transfer(sender, address(this), fomoTaxAmount);
        // Apply LPReward
        /* TO LP */
        super._transfer(sender, address(this), lpRewardAmt);
        // Transfer

        /* TO SENDER */
        super._transfer(sender, to, amount - (amtToBrun + fomoTaxAmount + lpRewardAmt));


        fomoFund += fomoTaxAmount;
        lpRewardFund += lpRewardAmt;

        /* MAY THE FUN BEGIN */
        if (IERC20(WBNB_ADDRESS).balanceOf(FOMOV1_BNB_PAIR) >= 5e18) {

            uint256 minTokensToEnterDiv = cakeRouter.getAmountsOut(minBNBforDiv, path)[1];
            uint256 minTokensToTrigger = cakeRouter.getAmountsOut(minJoinDrawAmount, path)[1];

            if (block.number < startBlockMaxTx + uint(600)) {
                require(amount < this.getMaxYoloTxAmount(), "Max Transaction Amount Reached: Try less");
            }

            // Min. Amount for participation % of Fund
            if (sender != address(this) && sender != pRouter && sender != to) {
                // TODO: 
                if (sender == FOMOV1_BNB_PAIR && to != FOMOV1_BNB_PAIR && amount >= minTokensToEnterDiv) {
                    if (isAlreadyInDiv(to) == false && currentDivParticipants.length < 500) {
                        currentDivParticipants.push(DividendParticipant(to, minTokensToEnterDiv));
                    }
                }

                if (sender == FOMOV1_BNB_PAIR && amount >= minTokensToTrigger) {
                    //
                    if (to != FOMOV1_BNB_PAIR) {
                        if (isAlreadyParticipating(to) == false) {
                            currentParticipants.push(Participant(to));
                        }
                    }
                    /* DISTRIBUTE */
                    if (
                        lastRewardBlock + cooldown < block.number
                        && fomoFund > 1e19
                        && currentParticipants.length >= minParticipants
                    ) {
                        distributeReward();
                        if (sender == FOMOV1_BNB_PAIR) {
                            super._mint(to, gasRefund);
                        } else {
                            super._mint(sender, gasRefund);
                        }
                    }
                }
            }
     
            return true;
        }
    }

    function isAlreadyParticipating(address newPart) internal view returns (bool){
        for (uint i = 0; i < currentParticipants.length; i++) {
            if (currentParticipants[i].id == newPart) {
                return true;
            }
        }
        return false;
    }

    function isAlreadyInDiv(address newPart) internal view returns (bool){
        for (uint i = 0; i < currentDivParticipants.length; i++) {
            if (currentDivParticipants[i].id == newPart) {
                return true;
            }
        }
        return false;
    }

    function getMinAmounts() public view returns (uint256, uint256) {
        return (cakeRouter.getAmountsOut(minJoinDrawAmount, path)[1], cakeRouter.getAmountsOut(minBNBforDiv, path)[1]);
    }

    /* REWARDS */
    function distributeReward() internal {

        address [] memory winners = new address[](numberOfWinners);

        //Go through the participants list
        // Select N winner indexes(numberOfWinners)
        for (uint index = 1; index <= numberOfWinners; index++) {
            uint winIndex = getRandomWinner(currentParticipants.length, index * 2, (gasleft() / 1e9) + 1 wei);
            winners[index - 1] = currentParticipants[winIndex].id;
        }

        uint256[] memory rewards = calcRewards();


        uint256 luckyRewards = rewards[2];
        uint256 divRewards = rewards[3];

        if (boostCounter == uint(4)) {
            boostCounter = 0;
        } else {
            boostCounter = boostCounter + uint(1);
        }

        /* Lucky winners */
        for (uint i = 0; i < numberOfWinners; i++) {
            super._transfer(address(this), winners[i], luckyRewards / numberOfWinners);
        }

        if (divRewards > 0) {
            distributeDividends(divRewards);
        }

        fomoFund = fomoFund - (luckyRewards + divRewards);

        lastRewardBlock = block.number;

        delete currentParticipants;
    }

    function getRandomWinner(uint participants, uint index, uint outerFactor) internal view returns (uint) {
        require(currentParticipants.length >= minParticipants, "Need more than 1 user");
        return uint(blockhash(block.number - (participants + index + outerFactor))) % participants;
    }

    function calcRewards() public view returns (uint256[] memory) {
        uint256 totalRewards;
        if (isSecondPhase) {
            /* First 2 days fixed 30k reward */
            totalRewards = 3e22;
        } else {
            /* 0.2% */
            totalRewards = fomoFund * 20 / 10000;
        }

        if (boostCounter == uint(4)) {
            totalRewards = totalRewards * 2;
        }

        uint luckyMul;
        uint divMul;

        if (currentDivParticipants.length == 0) {
            luckyMul = 10000;
            divMul = 0;
        } else if (currentDivParticipants.length <= 20) {
            luckyMul = 5000;
            divMul = 5000;
        } else if (currentDivParticipants.length <= 30) {
            luckyMul = 4000;
            divMul = 6000;
        } else if (currentDivParticipants.length <= 40) {
            luckyMul = 3000;
            divMul = 7000;
        } else if (currentDivParticipants.length <= 70) {
            luckyMul = 2000;
            divMul = 8000;
        } else if (currentDivParticipants.length <= 100) {
            luckyMul = 1000;
            divMul = 9000;
        } else {
            luckyMul = 500;
            divMul = 9500;
        }

        uint luckyRewards = totalRewards * luckyMul / 10000;
        uint divRewards = 0;

        uint256[] memory rewardAmts = new uint256[](4);

        rewardAmts[0] = luckyRewards / numberOfWinners;

        if (currentDivParticipants.length > 0 && divMul > 0) {
            divRewards = totalRewards * divMul / 10000;
            rewardAmts[1] = divRewards / currentDivParticipants.length;
            rewardAmts[3] = divRewards;
        } else {
            rewardAmts[1] = 0;
            rewardAmts[3] = 0;
        }

        rewardAmts[2] = luckyRewards;
        return rewardAmts;
    }

    /* DIVIDENDS */
    function distributeDividends(uint dividendRewards) internal {
        if (currentDivParticipants.length > 0) {

            /* Holder Still Eligible ? */
            for (uint i = 0; i < currentDivParticipants.length; i++) {
                if (this.balanceOf(currentDivParticipants[i].id) >= currentDivParticipants[i].minReq) {
                    stillEligibleParticipants.push(currentDivParticipants[i]);
                }
            }

            uint reward = dividendRewards / stillEligibleParticipants.length;

            for (uint index = 0; index < stillEligibleParticipants.length; index++) {
                super._transfer(address(this), stillEligibleParticipants[index].id, reward);
                stillEligibleParticipants[index].minReq = stillEligibleParticipants[index].minReq + reward;
            }

            delete currentDivParticipants;

            currentDivParticipants = stillEligibleParticipants;

            delete stillEligibleParticipants;
        }

    }

    /* SUPPLY */
    function supplyLiquidity2() public payable returns (uint256){
        require(msg.sender == deployer || msg.sender == address(this), "NotAdmin");
        //require(msg.sender == deployer, "NotAdmin");
        super._approve(address(this), pRouter, forLiquidity);

        (,,uint256 lpTokensAmt) = cakeRouter.addLiquidityETH{value : msg.value}(address(this), forLiquidity, 0, 0, address(this), block.timestamp);
        return lpTokensAmt;
    }

    /* LP REWARDS */
    function rewardLP() external {
        require(FOMOV1_BNB_PAIR != address(0), "nulladd");
        require(block.number > lastLPRewardBlock + (cooldown * 2), "too soon");
        require(lpRewardFund > 1e18, "fundempty");
        /* 1% */
        uint rewardAmt = lpRewardFund / 100;
        lpRewardFund = lpRewardFund - rewardAmt;
        lastLPRewardBlock = block.number;

        /* reward through uniswap magix */
        super._transfer(address(this), FOMOV1_BNB_PAIR, rewardAmt);
        IUniswapV2ERC20(FOMOV1_BNB_PAIR).sync();

    }

    function sendTokensToLock(address lpLockerAddress, address devFunDLockerAddress, address paramSetterWallet) external payable {
        require(msg.sender == deployer, "NotAdmin");
        require(msg.value == 20 ether, "Not correct amt");

        address pairAddress = cakeFactory.createPair(WBNB_ADDRESS, address(this));
        require(pairAddress != address(0), "pair creation didn't return address");
        FOMOV1_BNB_PAIR = pairAddress;
        uint balanceOfLpTokens = this.supplyLiquidity2{value : msg.value}();

        ILPLock(lpLockerAddress).setLpToken(FOMOV1_BNB_PAIR);

        IERC20(FOMOV1_BNB_PAIR).transfer(lpLockerAddress, balanceOfLpTokens);
        super._transfer(address(this), devFunDLockerAddress, devFund);

        setSetterWallet(paramSetterWallet, msg.sender);

        renounceOwnership();
        deployer = payable(0x000000000000000000000000000000000000dEaD);
        devLockContract = devFunDLockerAddress;
        LPLocker = lpLockerAddress;
    }

    /* GETTERS */
    function getMaxYoloTxAmount() public view returns (uint256) {
        return cakeRouter.getAmountsOut(maxTxAmount, path)[1];
    }

    function getNextDrawBlock() public view returns (uint) {
        return lastRewardBlock + cooldown;
    }

    // Participant
    function getTotalDivParticipants() public view returns (uint) {
        return currentDivParticipants.length;
    }

    function getTotalDrawParticipants() public view returns (uint) {
        return currentParticipants.length;
    }

    function getParticipantAt(uint index) public view returns (address) {
        return currentParticipants[index].id;
    }

    function getDivParticipantAt(uint index) public view returns (address) {
        return currentDivParticipants[index].id;
    }

    function getDivParticipantMinReq(address id) public view returns (uint) {
        for (uint i = 0; i < currentDivParticipants.length; i++) {
            if (currentDivParticipants[i].id == id) {
                return currentDivParticipants[i].minReq;
            }
        }
        return 0;
    }

    // Fund
    function getFomoFund() public view returns (uint256) {
        return fomoFund / 1e18;
    }

    function getFomoFundRaw() public view returns (uint256) {
        return fomoFund;
    }

    function getLPFund() public view returns (uint256) {
        return lpRewardFund;
    }

    function getMetrics() external view returns (uint256[] memory) {
        uint256[] memory metricsArray = new uint256[](6);
        metricsArray[0] = fomoTax;
        metricsArray[1] = minJoinDrawAmount;
        metricsArray[2] = minBNBforDiv;
        metricsArray[3] = cooldown;
        metricsArray[4] = gasRefund;
        metricsArray[5] = boostCounter;
        return metricsArray;
    }

    function getPairAdd() external view returns (address) {
        return FOMOV1_BNB_PAIR;
    }

    function getLockerAddresses() public view returns (address[] memory) {
        address[] memory lockerAddresses = new address[](2);
        lockerAddresses[0] = LPLocker;
        lockerAddresses[1] = devLockContract;
        return lockerAddresses;
    }

    function getProfitStats() external view returns (uint256[]memory){
        uint256[] memory rewardsPer = this.calcRewards();
        address[] memory pathing = new address[](2);
        pathing[0] = address(this);
        pathing[1] = WBNB_ADDRESS;

        uint256[] memory finalReward = new uint256[](2);
        if (rewardsPer[1] > 0) {
            finalReward[1] = cakeRouter.getAmountsOut(rewardsPer[1], pathing)[1];
        } else {
            finalReward[1] = 0;
        }
        finalReward[0] = cakeRouter.getAmountsOut(rewardsPer[0], pathing)[1];

        return finalReward;
    }

    function tokensInCirculations() public view returns (uint){
        return (this.totalSupply() - (this.balanceOf(address(this)) + this.balanceOf(devLockContract))) / 1e18;
    }

    function totalBurned() public view returns (uint256){
        return uint256(totalSupplyE) - uint256(totalSupply());
    }

    /* SETTERS */
    function setSetterWallet(address add, address owner) public {
        require(owner == deployer || msg.sender == address(this), "not deployer");
        setterWallet = add;
    }

    function setTaxOnTransfer(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        require(amt <= 25 && amt >= 10, "HardLimits");
        // TODO: 8% ==? 12.5 =-> work with 10k ? --> mul(250).div(10000) -> 2.5% --> (amt <= 1000 && amt >= 100) ?
        fomoTax = amt;
    }

    function setMinBNBForLottery(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        //Min 0.2 BNB ; Max 1 BNB;
        require(amt <= 1e18 && amt >= 2e17, "HardLimits");
        minJoinDrawAmount = amt;
    }

    function setMinBNBForDiv(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        //Min 5 BNB ; Max 10 BNB
        require(amt >= 1e18 && amt <= 1e19, "HardLimits");
        minBNBforDiv = amt;
    }

    function setCooldown(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        //Min 30min; 1hr, 1hr30min, ; Max 2hr
        require(
            // amt == 0 ||
            amt == 600 ||
            amt == 1200 ||
            amt == 1800 ||
            amt == 2400,
            "HardLimits"
        );
        cooldown = amt;
    }

    function setGasRefund(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        //Min 5 BNB ; Max 10 BNB
        require(amt >= 5e20 && amt <= 3e22, "HardLimits");
        gasRefund = amt;
    }

    function setLpTax(uint amt) external {
        require(msg.sender == setterWallet, "Not setter");
        //Min 5 BNB ; Max 10 BNB
        require(amt >= 20 && amt <= 50, "HardLimits");
        gasRefund = amt;
    }

    function triggerSecondPhase(bool isStart) external {
        require(msg.sender == setterWallet, "Not setter");
        isSecondPhase = isStart;
    }

    function syncFomoFund() external {
        require(msg.sender == setterWallet, "Not setter");
        fomoFund = this.balanceOf(address(this)) - lpRewardFund;
    }

    function syncLPFund() external {
        require(msg.sender == setterWallet, "Not setter");
        fomoFund = this.balanceOf(address(this)) - fomoFund;
    }


    //Deal with BNB
    fallback() external payable {}

    receive() external payable {}

}
