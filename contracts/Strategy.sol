// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
// Gary's Branch - YFI/WOOFY - 0xDAO
// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

struct route {
    address from;
    address to;
    bool stable;
}

interface IOTCTrader {
    function trade(address _tokenIn, uint256 _amount) external;
}

interface IOxPool {
    function stakingAddress() external view returns (address);

    function solidPoolAddress() external view returns (address);

    function depositLpAndStake(uint256) external;

    function depositLp(uint256) external;

    function withdrawLp(uint256) external;

    function syncBribeTokens() external;

    function notifyBribeOrFees() external;

    function initialize(
        address,
        address,
        address,
        string memory,
        string memory,
        address,
        address
    ) external;

    function gaugeAddress() external view returns (address);

    function balanceOf(address) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);
}

interface IMultiRewards {
    struct Reward {
        address rewardsDistributor;
        uint256 rewardsDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    function stake(uint256) external;

    function withdraw(uint256) external;

    function getReward() external;

    function stakingToken() external view returns (address);

    function balanceOf(address) external view returns (uint256);

    function earned(address, address) external view returns (uint256);

    function initialize(address, address) external;

    function rewardRate(address) external view returns (uint256);

    function getRewardForDuration(address) external view returns (uint256);

    function rewardPerToken(address) external view returns (uint256);

    function rewardData(address) external view returns (Reward memory);

    function rewardTokensLength() external view returns (uint256);

    function rewardTokens(uint256) external view returns (address);

    function totalSupply() external view returns (uint256);

    function addReward(
        address _rewardsToken,
        address _rewardsDistributor,
        uint256 _rewardsDuration
    ) external;

    function notifyRewardAmount(address, uint256) external;

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external;

    function setRewardsDuration(address _rewardsToken, uint256 _rewardsDuration)
        external;

    function exit() external;
}

interface ISolidlyRouter {
    function addLiquidity(
        address,
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokensSimple(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ITradeFactory {
    function enable(address, address) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // swap stuff
    address internal constant solidlyRouter =
        0xa38cd27185a464914D3046f0AB9d43356B34829D;
    bool public tradesEnabled;
    bool public realiseLosses;
    bool public depositerAvoid;
    address public tradeFactory = 0xD3f89C21719Ec5961a3E6B0f9bBf9F9b4180E9e9;

    address public solidPoolAddress = 
        address(0x4b3a172283ecB7d07AB881a9443d38cB1c98F4d0);
    address public oxPoolAddress = 
        address(0x5473DE6376A5DA114DE21f63E673fE76e509e55C);
    address public stakingAddress = 
        address(0x2799e089550979D5E268559bEbca3990dCbeD18b);

    IERC20 internal constant solidLp =
        IERC20(0x4b3a172283ecB7d07AB881a9443d38cB1c98F4d0); // Solidly YFI/WOOFY
    IERC20 internal constant oxLp =
        IERC20(0x5473DE6376A5DA114DE21f63E673fE76e509e55C); // 0xDAO YFI/WOOFY

    IERC20 internal constant yfi =
        IERC20(0x29b0Da86e484E1C0029B56e817912d778aC0EC69);
    IERC20 internal constant woofy =
        IERC20(0xD0660cD418a64a1d44E9214ad8e459324D8157f1);

    IERC20 internal constant solid =
        IERC20(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);
    IERC20 internal constant oxd =
        IERC20(0xc5A9848b9d145965d821AaeC8fA32aaEE026492d);

    // should we lower this???
    uint256 public lpSlippage = 9950; //0.5% slippage allowance

    uint256 immutable DENOMINATOR = 10_000;

    string internal stratName; // we use this for our strategy's name on cloning
    address public lpToken = 0x4b3a172283ecB7d07AB881a9443d38cB1c98F4d0; //var yfi/woofy // This will disappear in a clone!
    IOxPool public oxPool =
        IOxPool(0x5473DE6376A5DA114DE21f63E673fE76e509e55C);
    IMultiRewards public multiRewards =
        IMultiRewards(0x2799e089550979D5E268559bEbca3990dCbeD18b);
    uint256 dustThreshold = 1e14;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy
    IOTCTrader public otcSwapper;

    bool public takeLosses;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _name, address _otctrader)
        public
        BaseStrategy(_vault)
    {
        _initializeStrat(_name, _otctrader);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(string memory _name, address _otctrader) internal {
        // initialize variables
        maxReportDelay = 43200; // 1/2 day in seconds, if we hit this then harvestTrigger = True
        healthCheck = 0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0; // Fantom common health check

        // set our strategy's name
        stratName = _name;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        IERC20(lpToken).approve(address(solidlyRouter), type(uint256).max);
        woofy.approve(address(solidlyRouter), type(uint256).max);
        yfi.approve(address(solidlyRouter), type(uint256).max);
        // NEW ONES
        IERC20(solidPoolAddress).approve(oxPoolAddress, type(uint256).max);
        IERC20(oxPoolAddress).approve(stakingAddress, type(uint256).max);

        IOTCTrader _trader = IOTCTrader(_otctrader);
        _setupOTCTrader(address(_trader));
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    // balance of yfi in strat - should be zero most of the time
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // balance of woofy in strat - should be zero most of the time
    function balanceOfWoofy() public view returns (uint256) {
        return woofy.balanceOf(address(this));
    }

    // view our balance of unstaked oxLP tokens - should be zero most of the time
    function balanceOfOxPool() public view returns (uint256) {
        return oxPool.balanceOf(address(this));
    }

    // view our balance of staked oxLP tokens
    function balanceOfMultiRewards() public view returns (uint256) {
        return multiRewards.balanceOf(address(this));
    }

    // view our balance of unstaked and staked oxLP tokens
    function balanceOfLPStaked() public view returns (uint256) {
        return balanceOfOxPool().add(balanceOfMultiRewards());
    }

    function balanceOfConstituents(uint256 liquidity)
        public
        view
        returns (uint256 amountYfi, uint256 amountWoofy)
    {
        (amountYfi, amountWoofy) = ISolidlyRouter(solidlyRouter)
            .quoteRemoveLiquidity(
                address(yfi),
                address(woofy),
                false, // volatile pool
                liquidity
            );
    }

    //yfi and woofy are interchangeable 1-1. so we need our balance of each. added to whatever we can withdraw from lps
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 lpTokens = balanceOfLPStaked().add(
            IERC20(lpToken).balanceOf(address(this))
        );

        (uint256 amountYfi, uint256 amountWoofy) = balanceOfConstituents(
            lpTokens
        );

        return	
            amountWoofy.add(balanceOfWoofy()).add(balanceOfWant()).add(	
                amountYfi	
            );	
    }

    // NOT TRUE ANYMORE... our main trigger is regarding our DCA since there is low liquidity for our emissionToken
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // trigger if we have enough credit
        if (vault.creditAvailable() >= minHarvestCredit) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        if (tradesEnabled == false && tradeFactory != address(0)) {
            _setUpTradeFactory();
        }
        // claim our rewards
        multiRewards.getReward();

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        if (assets >= debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets.sub(debt);

            amountToFree = _profit.add(_debtPayment);
        } else {
            //loss should never happen. so leave blank. small potential for IP i suppose. lets not record if so and handle manually
            //dont withdraw either incase we realise losses
            //withdraw with loss
            if (realiseLosses) {
                _loss = debt.sub(assets);
                if (_debtOutstanding > _loss) {	
                    _debtPayment = _debtOutstanding.sub(_loss);	
                } else {	
                    _debtPayment = 0;	
                }

                amountToFree = _debtPayment;
            }
        }

        //amountToFree > 0 checking (included in the if statement)
        if (wantBal < amountToFree) {
            liquidatePosition(amountToFree);

            uint256 newLoose = want.balanceOf(address(this));

            //if we dont have enough money adjust _debtOutstanding and only change profit if needed
            if (newLoose < amountToFree) {
                if (_profit > newLoose) {
                    _profit = newLoose;
                    _debtPayment = 0;
                } else {
                    _debtPayment = Math.min(newLoose - _profit, _debtPayment);
                }
            }
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    //you need to swap token of amount to arb the peg
    function neededToArbPeg()
        public
        view
        returns (address token, uint256 amount)
    {
        uint256 yfiInLp = yfi.balanceOf(lpToken);
        uint256 woofyInLp = woofy.balanceOf(lpToken);

        //if arb is less than fees then no arb
        if (
            yfiInLp.mul(1_000) > woofyInLp.mul(999) &&
            woofyInLp.mul(1_000) > yfiInLp.mul(999)
        ) {
            return (address(yfi), 0);
        }

        //sqrt(yfiInLp*woofyInLp)-smaller
        //this should return to peg ignoring fees
        uint256 sq = sqrt(yfiInLp.mul(woofyInLp));

        //if lp is unbalanced we need to arb it back to peg. if too much yfi in lp buy yfi. if too much woofy buy woofy
        if (yfiInLp > woofyInLp) {
            amount = sq.sub(woofyInLp);
            token = address(woofy);
        } else {
            amount = sq.sub(yfiInLp);
            token = address(yfi);
        }
    }

    //get token of amount from otc
    function _getFromOTC(IERC20 token, uint256 amount)
        internal
        returns (uint256 newBalance)
    {
        //the token in is opposite of what we want out
        address tokenIn = address(token) == address(yfi)
            ? address(woofy)
            : address(yfi);

        newBalance = token.balanceOf(address(this));
        //the balance of what we need to provide the swapper
        uint256 balanceIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenInSwapper = token.balanceOf(address(otcSwapper));

        //if there isnt enough in the swapper, adjust what we ask for
        if (tokenInSwapper < amount) {
            amount = tokenInSwapper;
        }
        //if we cant afford to provide the tokenin for the amount we want, adjust what we ask for
        if (balanceIn < amount) {
            amount = balanceIn;
        }

        //if the amount to swap is tiny dont bother
        if (amount > dustThreshold) {
            otcSwapper.trade(tokenIn, Math.min(amount, tokenInSwapper));
            newBalance = token.balanceOf(address(this));
        }
    }

    function arbThePeg() external onlyEmergencyAuthorized {
        _arbThePeg();
    }

    function _arbThePeg() internal {
        (address token, uint256 amount) = neededToArbPeg();
        address tokenOut = token == address(yfi)
            ? address(woofy)
            : address(yfi);

        if (amount < dustThreshold) {
            return;
        }

        uint256 yfiBalance = balanceOfWant();
        uint256 woofyBalance = balanceOfWoofy();

        uint256 toBuy;

        if (token == address(yfi)) {
            if (yfiBalance < amount) {
                yfiBalance = _getFromOTC(yfi, amount - yfiBalance);
            }

            toBuy = Math.min(amount, yfiBalance);
        } else if (token == address(woofy)) {
            if (woofyBalance < amount) {
                woofyBalance = _getFromOTC(woofy, amount - woofyBalance);
            }

            toBuy = Math.min(amount, woofyBalance);
        }

        if (toBuy < dustThreshold) {
            return;
        }

        ISolidlyRouter(solidlyRouter).swapExactTokensForTokensSimple(
            toBuy,
            toBuy,
            token,
            tokenOut,
            false,
            address(this),
            type(uint256).max
        );
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        _arbThePeg();

        uint256 yfiInLp = yfi.balanceOf(lpToken);
        uint256 woofyInLp = woofy.balanceOf(lpToken);

        if (
            yfiInLp.mul(DENOMINATOR) < woofyInLp.mul(lpSlippage) ||
            woofyInLp.mul(DENOMINATOR) < yfiInLp.mul(lpSlippage)
        ) {
            //if the pool is still imbalanced after the arb dont do anything
            return;
        }

        uint256 yfiBalance = balanceOfWant();
        uint256 woofyBalance = balanceOfWoofy();

        //need equal yfi and woofy
        if (yfiBalance > woofyBalance) {
            uint256 desiredWoofy = (yfiBalance - woofyBalance) / 2;
            _getFromOTC(woofy, desiredWoofy);
        } else {
            uint256 desiredYfi = (woofyBalance - yfiBalance) / 2;
            _getFromOTC(yfi, desiredYfi);
        }

        yfiBalance = balanceOfWant();
        woofyBalance = balanceOfWoofy();

        if (yfiBalance < dustThreshold || woofyBalance < dustThreshold) {
            return;
        }

        ISolidlyRouter(solidlyRouter).addLiquidity(
            address(yfi),
            address(woofy),
            false,
            yfiBalance,
            woofyBalance,
            0,
            0,
            address(this),
            2**256 - 1
        );

        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));

        if (lpBalance > 0) {	
            // Transfer Solidly LP to ox pool to receive Ox pool LP receipt token	
            oxPool.depositLp(lpBalance);	
            // Stake oxLP in multirewards	
            multiRewards.stake(oxLp.balanceOf(address(this)));	
        }
    }

    function _setUpTradeFactory() internal {
        //approve and set up trade factory
        address _tradeFactory = tradeFactory;

        ITradeFactory tf = ITradeFactory(_tradeFactory);
        oxd.safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(address(oxd), address(want));

        solid.safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(address(solid), address(want));
        tradesEnabled = true;
    }

    //returns lp tokens needed to get that amount of yfi
    function yfiToLpTokens(uint256 amountOfYfiWeWant) public returns (uint256) {
        //amount of yfi and woofy for 1 lp token
        (uint256 amountYfiPerLp, uint256 amountWoofy) = balanceOfConstituents(
            1e18
        );

        //1 lp token is this amoubt of boo
        amountYfiPerLp = amountYfiPerLp.add(amountWoofy);

        uint256 lpTokensWeNeed = amountOfYfiWeWant.mul(1e18).div(
            amountYfiPerLp
        );

        return lpTokensWeNeed;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceOfYfi = want.balanceOf(address(this));

        // if we need more yfi than is already loose in the contract
        if (balanceOfYfi < _amountNeeded) {
            // yfi needed beyond any yfi that is already loose in the contract
            uint256 amountToFree = _amountNeeded.sub(balanceOfYfi);

            // converts this amount into lpTokens
            uint256 lpTokensNeeded = yfiToLpTokens(amountToFree);

            uint256 balanceOfLpTokens = IERC20(lpToken).balanceOf(
                address(this)
            );

            if (balanceOfLpTokens < lpTokensNeeded) {
                uint256 toWithdrawfromOxdao = lpTokensNeeded.sub(
                    balanceOfLpTokens
                );

                 // balance of oxlp staked in multiRewards
                uint256 staked = balanceOfLPStaked();
                if (staked > 0) {
                    // Withdraw oxLP from multiRewards	
                    multiRewards.withdraw(Math.min(toWithdrawfromOxdao, staked));	
                    // our balance of oxlp in oxPool	
                    uint256 oxLpBalance = oxPool.balanceOf(address(this));	
                    // Redeem/burn oxPool LP for Solidly LP	
                    oxPool.withdrawLp(Math.min(toWithdrawfromOxdao, oxLpBalance));
                }

                balanceOfLpTokens = IERC20(lpToken).balanceOf(address(this));
            }

            if (balanceOfLpTokens > 0) {
                ISolidlyRouter(solidlyRouter).removeLiquidity(
                    address(yfi),
                    address(woofy),
                    false,
                    Math.min(lpTokensNeeded, balanceOfLpTokens),
                    0,
                    0,
                    address(this),
                    type(uint256).max
                );
            }

            //now we have a bunch of yfi and woofy

            //now we swap if we can at a profit
            uint256 yfiInLp = yfi.balanceOf(lpToken);
            uint256 woofyInLp = woofy.balanceOf(lpToken);
            if (yfiInLp > woofyInLp.add(dustThreshold)) {
                //we can arb
                _arbThePeg();
            }

            balanceOfYfi = want.balanceOf(address(this));
            if (balanceOfYfi < _amountNeeded) {
                balanceOfYfi = _getFromOTC(yfi, _amountNeeded - balanceOfYfi);
            }

            _liquidatedAmount = Math.min(balanceOfYfi, _amountNeeded);

            if (_liquidatedAmount < _amountNeeded) {
                _loss = _amountNeeded.sub(_liquidatedAmount);
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // our balance of oxlp staked in multiRewards	
        uint256 staked = balanceOfLPStaked();	
        if (staked > 0) {	
            // Withdraw oxLP from multiRewards	
            multiRewards.withdraw(staked);	
            // our balance of oxlp in oxPool	
            uint256 oxLpBalance = oxPool.balanceOf(address(this));	
            // Redeem/burn oxPool LP for Solidly LP	
            oxPool.withdrawLp(oxLpBalance);
        }
        ISolidlyRouter(solidlyRouter).removeLiquidity(
            address(yfi),
            address(woofy),
            false,
            IERC20(lpToken).balanceOf(address(this)),
            0,
            0,
            address(this),
            type(uint256).max
        );
        _getFromOTC(yfi, type(uint256).max); //swap all we can

        //if we have woofy left revert
        if (!takeLosses) {
            require(balanceOfWoofy() == 0);
        }

        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (!depositerAvoid) {
            // our balance of oxlp staked in multiRewards	
            uint256 staked = balanceOfLPStaked();	
            if (staked > 0) {	
                // Withdraw oxLP from multiRewards	
                multiRewards.withdraw(staked);	
                // our balance of oxlp in oxPool	
                uint256 oxLpBalance = oxPool.balanceOf(address(this));	
                // Redeem/burn oxPool LP for Solidly LP	
                oxPool.withdrawLp(oxLpBalance);
            }
        }

        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));

        if (lpBalance > 0) {
            IERC20(lpToken).safeTransfer(_newStrategy, lpBalance);
        }

        uint256 woofyBalance = woofy.balanceOf(address(this));

        if (woofyBalance > 0) {
            // send our total balance of woofy to the new strategy
            woofy.transfer(_newStrategy, woofyBalance);
        }
    }

    // Withdraw all oxLP (and rewards) from multiRewards and Redeem/burn oxPool LP for Solidly LP	
    function manualCompleteExit()	
        external	
        onlyEmergencyAuthorized	
    {	
        // Withdraw all oxLP (and rewards) from multiRewards	
        multiRewards.exit();	
        // our balance of oxlp in oxPool	
        uint256 oxLpBalance = oxPool.balanceOf(address(this));	
        // Redeem/burn oxPool LP for Solidly LP	
        oxPool.withdrawLp(oxLpBalance);	
    }
    	
    // Withdraw oxLP from multiRewards and Redeem/burn oxPool LP for Solidly LP	
    function manualCompleteExit(uint256 amount)	
        external	
        onlyEmergencyAuthorized	
    {	
        _manualUnstake(amount);
        // our balance of oxlp in oxPool
        uint256 oxLpBalance = oxPool.balanceOf(address(this));
        _manualWithdrawLP(Math.min(amount, oxLpBalance));
    }

    // Withdraw oxLP from multiRewards	
    function manualUnstake(uint256 amount)
        external	
        onlyEmergencyAuthorized	
    {	
        _manualUnstake(amount);
    }

    // Withdraw oxLP from multiRewards	
    function _manualUnstake(uint256 amount)
        internal	
    {	
        multiRewards.withdraw(amount);	
    }

    // Redeem/burn oxPool LP for Solidly LP	
    function manualWithdrawLP(uint256 amount)	
        external	
        onlyEmergencyAuthorized	
    {	
        _manualWithdrawLP(amount);	
    }

    // Redeem/burn oxPool LP for Solidly LP	
    function _manualWithdrawLP(uint256 amount)	
        internal
    {	
        oxPool.withdrawLp(amount);	
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function _setupOTCTrader(address _trader) internal {
        if (address(otcSwapper) != address(0)) {
            woofy.approve(address(otcSwapper), 0);
            yfi.approve(address(otcSwapper), 0);
        }

        otcSwapper = IOTCTrader(_trader);

        woofy.approve(_trader, type(uint256).max);
        yfi.approve(_trader, type(uint256).max);
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        address _tradeFactory = tradeFactory;
        oxd.safeApprove(_tradeFactory, 0);

        solid.safeApprove(_tradeFactory, 0);

        tradeFactory = address(0);
        tradesEnabled = false;
    }

    /* ========== SETTERS ========== */

    function setTakeLosses(bool _takeLosses) external onlyVaultManagers {
        takeLosses = _takeLosses;
    }

    function removeOTCTraderPermissions() external onlyEmergencyAuthorized {
        woofy.approve(address(otcSwapper), 0);
        yfi.approve(address(otcSwapper), 0);
    }

    function updateTradeFactory(address _newTradeFactory)
        external
        onlyGovernance
    {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        tradeFactory = _newTradeFactory;
        _setUpTradeFactory();
    }

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyEmergencyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice When our strategy has this much credit, harvestTrigger will be true.
    function setMinHarvestCredit(uint256 _minHarvestCredit)
        external
        onlyEmergencyAuthorized
    {
        minHarvestCredit = _minHarvestCredit;
    }

    ///@notice When our strategy has this much credit, harvestTrigger will be true.
    function setRealiseLosses(bool _realiseLoosses)
        external
        onlyVaultManagers
    {
        realiseLosses = _realiseLoosses;
    }

    function setLpSlippage(uint256 _slippage) external onlyEmergencyAuthorized {
        _setLpSlippage(_slippage, false);
    }

    //only vault managers can set high slippage
    function setLpSlippage(uint256 _slippage, bool _force)
        external
        onlyVaultManagers
    {
        _setLpSlippage(_slippage, _force);
    }

    function _setLpSlippage(uint256 _slippage, bool _force) internal {
        require(_slippage <= DENOMINATOR, "higher than max");
        if (!_force) {
            require(_slippage >= 9900, "higher than 1pc slippage set");
        }
        lpSlippage = _slippage;
    }

    function setDepositerAvoid(bool _avoid) external onlyGovernance {
        depositerAvoid = _avoid;
    }

    function setDusetThreshold(uint256 _dust) external onlyEmergencyAuthorized {
        dustThreshold = _dust;
    }
}
