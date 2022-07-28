// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
// Gary's SSV Strat - USDC/sUSD
// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

interface IVelodromeRouter {
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
}

interface IGauge {
    function deposit(
        uint amount,
        uint tokenId
    ) public lock;

    function claimFees(

    )
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
    address internal constant velodromeRouter =
        0xa132DAB612dB5cB9fC9Ac426A0Cc215A3423F9c9;
    bool public tradesEnabled;
    bool public realiseLosses;
    bool public depositerAvoid;
    // address public tradeFactory = 0xD3f89C21719Ec5961a3E6B0f9bBf9F9b4180E9e9;

    address public velodromePoolAddress = 
        address(0xd16232ad60188B68076a235c65d692090caba155); // StableV1 AMM - USDC/sUSD
    address public stakingAddress = 
       address(0xb03f52D2DB3e758DD49982Defd6AeEFEa9454e80); // Gauge

    IERC20 internal constant usdc =
        IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IERC20 internal constant susd =
        IERC20(0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9);

    IERC20 internal constant velo =
        IERC20(0x3c8B650257cFb5f272f799F5e2b4e65093a11a05);

    uint256 public lpSlippage = 9995; //0.05% slippage allowance

    uint256 immutable DENOMINATOR = 10_000;

    string internal stratName; // we use this for our strategy's name on cloning

    IGauge public gauge =
       IGauge(0xb03f52D2DB3e758DD49982Defd6AeEFEa9454e80);

    uint256 dustThreshold = 1e14;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy

    bool public takeLosses;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _name)
        public
        BaseStrategy(_vault)
    {
        _initializeStrat(_name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(string memory _name) internal {
        // initialize variables
        maxReportDelay = 43200; // 1/2 day in seconds, if we hit this then harvestTrigger = True
        healthCheck = 0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0; // Fantom common health check NEED TO CHANGE THIS TO OPTIMISM

        // set our strategy's name
        stratName = _name;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        IERC20(velodromePoolAddress).approve(address(velodromeRouter), type(uint256).max);
        usdc.approve(address(velodromeRouter), type(uint256).max);
        susd.approve(address(velodromeRouter), type(uint256).max);
        IERC20(velodromePoolAddress).approve(stakingAddress, type(uint256).max);
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

    // view our balance of unstaked solidLP tokens - should be zero most of the time
    function balanceOfsolidPool() public view returns (uint256) {
        return IERC20(solidPoolAddress).balanceOf(address(this));
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
        (amountYfi, amountWoofy) = IVelodromeRouter(velodromeRouter)
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
            balanceOfsolidPool()
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

            uint256 newLoose = balanceOfWant();

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

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 yfiBalance = balanceOfWant();
        uint256 woofyBalance = balanceOfWoofy();

        yfiBalance = balanceOfWant();
        woofyBalance = balanceOfWoofy();

        if (yfiBalance < dustThreshold || woofyBalance < dustThreshold) {
            return;
        }

        IVelodromeRouter(velodromeRouter).addLiquidity(
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

        uint256 lpBalance = balanceOfsolidPool();

        if (lpBalance > 0) {	
            // Deposit lp tokens into lp gauge	
            gauge.deposit(lpBalance);
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

        //1 lp token is this amount of yfi
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
        uint256 balanceOfYfi = balanceOfWant();

        // if we need more yfi than is already loose in the contract
        if (balanceOfYfi < _amountNeeded) {
            // yfi needed beyond any yfi that is already loose in the contract
            uint256 amountToFree = _amountNeeded.sub(balanceOfYfi);

            if (amountToFree > dustThreshold) {
                // converts this amount into lpTokens
                uint256 lpTokensNeeded = yfiToLpTokens(amountToFree);

                uint256 balanceOfLpTokens = balanceOfsolidPool();

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
                        uint256 oxLpBalance = balanceOfOxPool();	
                        // Redeem/burn oxPool LP for Solidly LP	
                        oxPool.withdrawLp(Math.min(toWithdrawfromOxdao, oxLpBalance));
                    }

                    balanceOfLpTokens = balanceOfsolidPool();
                }

                if (balanceOfLpTokens > 0) {
                    IVelodromeRouter(velodromeRouter).removeLiquidity(
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

                balanceOfYfi = balanceOfWant();

                _liquidatedAmount = Math.min(balanceOfYfi, _amountNeeded);

                if (_liquidatedAmount < _amountNeeded) {
                    _loss = _amountNeeded.sub(_liquidatedAmount);
                }
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
            uint256 oxLpBalance = balanceOfOxPool();	
            // Redeem/burn oxPool LP for Solidly LP	
            oxPool.withdrawLp(oxLpBalance);
        }
        IVelodromeRouter(velodromeRouter).removeLiquidity(
            address(yfi),
            address(woofy),
            false,
            balanceOfsolidPool(),
            0,
            0,
            address(this),
            type(uint256).max
        );
        
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
                uint256 oxLpBalance = balanceOfOxPool();	
                // Redeem/burn oxPool LP for Solidly LP	
                oxPool.withdrawLp(oxLpBalance);
            }
        }

        uint256 lpBalance = balanceOfsolidPool();

        if (lpBalance > 0) {
            IERC20(solidPoolAddress).safeTransfer(_newStrategy, lpBalance);
        }

        uint256 woofyBalance = balanceOfWoofy();

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
        uint256 oxLpBalance = balanceOfOxPool();	
        // Redeem/burn oxPool LP for Solidly LP	
        oxPool.withdrawLp(oxLpBalance);	
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

    function setDustThreshold(uint256 _dust) external onlyEmergencyAuthorized {
        dustThreshold = _dust;
    }
}