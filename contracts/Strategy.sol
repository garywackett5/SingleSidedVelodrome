// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
// Gary's USDC SSV Strat - USDC/sUSD
// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

struct route {
    address from;
    address to;
    bool stable;
}

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
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function getAmountsOut(
        uint256 amountIn,
        route[] memory routes
    ) external view returns (uint256[] memory amounts);

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

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IGauge {
    function deposit(
        uint amount,
        uint tokenId
    ) public;

    // not sure if we need this function
    function claimFees() external returns (uint claimed0, uint claimed1);

    function withdraw(
        uint amount
    ) public;

    function derivedBalance(
        address account
    ) public view returns (uint);

    function getReward(
        address account,
        address[] memory tokens
    ) external;
}

interface IPool {
    function getReserves() public view returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // swap stuff
    address internal constant velodromeRouter =
        0xa132DAB612dB5cB9fC9Ac426A0Cc215A3423F9c9;
    bool public realiseLosses;
    bool public depositerAvoid;
    address[] public veloTokenPath; // path to sell VELO ARE THESE CORRECT???
    address[] public usdcToSusdPath; // path to sell VELO

    address public velodromePoolAddress = 
        address(0xd16232ad60188B68076a235c65d692090caba155); // StableV1 AMM - USDC/sUSD
    address public stakingAddress = 
       address(0xb03f52D2DB3e758DD49982Defd6AeEFEa9454e80); // Gauge

    // tokens
    IERC20 internal constant usdc =
        IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IERC20 internal constant susd =
        IERC20(0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9);
    IERC20 internal constant velo =
        IERC20(0x3c8B650257cFb5f272f799F5e2b4e65093a11a05);

    uint256 public lpSlippage = 9980; //0.2% slippage allowance

    uint256 immutable DENOMINATOR = 10_000;

    string internal stratName; // we use this for our strategy's name on cloning

    IPool public pool =
        IPool(0xd16232ad60188B68076a235c65d692090caba155);
    IGauge public gauge =
       IGauge(0xb03f52D2DB3e758DD49982Defd6AeEFEa9454e80);

    uint256 dustThreshold = 1e14; // need to set this correctly for usdc and susd

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _name)
        public
        BaseStrategy(_vault)
    {
        _initializeStrat(_name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(string memory _name) internal {
        // initialize variables
        maxReportDelay = 86400; // 1 day in seconds, if we hit this then harvestTrigger = True // NEED TO CHANGE THIS???
        healthCheck = 0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0; // Fantom common health check // NEED TO CHANGE THIS TO OPTIMISM!!!

        // set our strategy's name
        stratName = _name;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        IERC20(velodromePoolAddress).approve(address(velodromeRouter), type(uint256).max);
        usdc.approve(address(velodromeRouter), type(uint256).max);
        susd.approve(address(velodromeRouter), type(uint256).max);
        IERC20(velodromePoolAddress).approve(stakingAddress, type(uint256).max);

        // set our paths DO WE NEED TO TELL IT TO USE THE STABLE OR VOLATILE POOL???
        veloTokenPath = [address(velo), address(usdc)]; 
        usdcToSusdPath = [address(usdc), address(susd)];
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    // balance of usdc in strat - should be zero most of the time
    function balanceOfWant() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // balance of susd in strat - should be zero most of the time
    function balanceOfSusd() public view returns (uint256) {
        return susd.balanceOf(address(this));
    }

    // view our balance of unstaked velodrome LP tokens - should be zero most of the time
    function balanceOfLPUnstaked() public view returns (uint256) {
        return IERC20(velodromePoolAddress).balanceOf(address(this));
    }

    // view our balance of staked velodrome LP tokens
    function balanceOfLPStaked() public view returns (uint256) {
        // not sure this will work
        return gauge.derivedBalance(address(this));
    }

    // view our balance of unstaked and staked velodrome LP tokens
    function balanceOfLPTotal() public view returns (uint256) {
        return balanceOfLPUnstaked().add(balanceOfLPStaked());
    }

    function balanceOfConstituents(uint256 liquidity)
        public
        view
        returns (uint256 amountUsdc, uint256 amountSusd)
    {
        (amountUsdc, amountSusd) = IVelodromeRouter(velodromeRouter)
            .quoteRemoveLiquidity(
                address(usdc),
                address(susd),
                true, // stable pool
                liquidity
            );
    }

    // this treats usdc and susd as 1:1
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 lpTokens = balanceOfLPTotal();

        (uint256 amountUsdc, uint256 amountSusd) = balanceOfConstituents(
            lpTokens
        );

        return	
            amountSusd.add(balanceOfSusd()).add(balanceOfWant()).add(	
                amountUsdc
            );
    }

    // NOT TRUE ANYMORE... our main trigger is regarding our DCA since there is low liquidity for our emissionToken ???
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
        // claim our VELO rewards
        // but what if we need to claim other tokens??? sweep???
        gauge.getReward(address(this), address(velo));

        uint256 veloBalance = velo.balanceOf(address(this));

        // sell our claimed VELO rewards for USDC
            if (veloBalance > 0) {
                _sellVelo(veloBalance);
            }
        
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

        if (wantBal < amountToFree) {
            // should this be amountToFree.sub(wantBal)???
            liquidatePosition(amountToFree);

            uint256 newLoose = balanceOfWant();

            // if we dont have enough money adjust _debtOutstanding and only change profit if needed
            // i'm not 100% sure what's going on here
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

        // first we get the balance of each token in the pool
        // DONT FORGET: usdc (6 decimals), susd (18 decimals)
        uint256 usdcB = usdc.balanceOf(velodromePoolAddress).mul(1e12); // (now 18 decimals)
        uint256 susdB = susd.balanceOf(velodromePoolAddress);
        uint256 poolBalance = usdcB.add(susdB);
        uint256 amountIn = poolBalance.div(20); // 5% of poolBalance

        // because it is a stable pool, lets check slippage by doing a trade against it.
        route memory usdcToSusd = route(
            address(usdc),
            address(susd),
            true
        );

        // check usdc to susd slippage
        route[] memory routes = new route[](1);
        routes[0] = usdcToSusd;
        uint256 amountOut = IVelodromeRouter(velodromeRouter).getAmountsOut(
            amountIn, // swap 5% of poolBalance
            routes
        )[1];

        // allow up to 0.2% slippage on a swap of 5% of the poolBalance by default
        if (amountOut < amountIn.mul(lpSlippage).div(DENOMINATOR)) {
            // dont do anything because we would be lping into the pool at a bad price
            return;
        }

        // send all of our want tokens to be deposited
        uint256 usdcBal = balanceOfWant().mul(1e12); // now to 18 decimals (example, 1m)
        uint256 susdBal = balanceOfSusd();

        // dont bother for less than 10000 usdc
        if (usdcBal.add(susdBal) < 1e22) {
            return;
        }
        
        // first we get the ratio of each token in the pool. this determines how many we need of each
        // DONT FORGET: usdc (6 decimals), susd (18 decimals)
        uint256 usdcB = usdc.balanceOf(velodromePoolAddress).mul(1e12); // 5m (18 decimals)
        uint256 susdB = susd.balanceOf(velodromePoolAddress); // 5m (18 decimals)

        uint256 susdWeNeed = usdcBal.mul(susdB).div(usdcB.add(susdB)); // 500k (18 decimals)
        uint256 susdWeNeedInUsdc = susdWeNeed.div(1e12);
        uint256 usdcWeHaveToSwap = susdWeNeedInUsdc.sub(susdBal);
        uint256 usdcToSwap = math.min(usdcWeHaveToSwap, amountIn.div(1e12)); // amountIn = 5% of pool (converted back to 6 decimals)

        IVelodromeRouter(velodromeRouter).swapExactTokensForTokens(
            usdcToSwap,
            uint256(0),
            routes,
            address(this),
            block.timestamp
        )[1];
        
        usdcBalNew = balanceOfWant();
        susdBalNew = balanceOfSusd();

        if (anyWftmBal > 0 && wftmBal > 0) {
            // deposit into lp
            ISolidlyRouter(solidlyRouter).addLiquidity(
                address(usdc),
                address(susd),
                true,
                usdcBalNew,
                susdBalNew,
                0,
                0,
                address(this),
                2**256 - 1
            );
        }
    
        uint256 lpBalance = balanceOfLPUnstaked();

        if (lpBalance > 0) {
            // deposit to gauge
            gauge.deposit(lpBalance);
        }
    }

    // returns lp tokens needed to get that amount of usdc
    function usdcToLpTokens(uint256 amountOfYfiWeWant) public returns (uint256) {
        //amount of usdc and susd for 1 lp token
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
        uint256 balanceOfUsdc = balanceOfWant();

        // if we need more usdc than is already loose in the strategy
        if (balanceOfUsdc < _amountNeeded) {
            // amountToFree = the usdc needed beyond any usdc that is already loose in the strategy
            uint256 amountToFree = _amountNeeded.sub(balanceOfUsdc);

            if (amountToFree > dustThreshold) {
                // converts this amount into lpTokens
                uint256 lpTokensNeeded = usdcToLpTokens(amountToFree);

                uint256 balanceOfUnstaked = balanceOfLPUnstaked();

                if (balanceOfUnstaked < lpTokensNeeded) {
                    uint256 amountToUnstake = lpTokensNeeded.sub(
                        balanceOfUnstaked
                    );

                    // balance of lp tokens staked in gauge
                    uint256 balanceOfStaked = balanceOfLPStaked();
                    if (balanceOfStaked > 0) {
                        // Withdraw lp tokens from gauge	
                        gauge.withdraw(Math.min(amountToUnstake, balanceOfStaked));
                    }

                    balanceOfLpTokens = balanceOfLPUnstaked();
                }

                if (balanceOfLpTokens > 0) {
                    IVelodromeRouter(velodromeRouter).removeLiquidity(
                        address(usdc),
                        address(susd),
                        true,
                        Math.min(lpTokensNeeded, balanceOfLpTokens),
                        0,
                        0,
                        address(this),
                        type(uint256).max
                    );
                }

                balanceOfUsdc = balanceOfWant();

                _liquidatedAmount = Math.min(balanceOfUsdc, _amountNeeded);

                if (_liquidatedAmount < _amountNeeded) {
                    _loss = _amountNeeded.sub(_liquidatedAmount);
                }
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // balance of lp tokens staked in gauge	
        uint256 balanceOfStaked = balanceOfLPStaked();	
        if (balanceOfStaked > 0) {	
            // Withdraw lp tokens from gauge	
            gauge.withdraw(staked);	
        }

        balanceOfLpTokens = balanceOfLPUnstaked();

        IVelodromeRouter(velodromeRouter).removeLiquidity(
            address(usdc),
            address(susd),
            true,
            balanceOfLPTokens,
            0,
            0,
            address(this),
            type(uint256).max
        );
        
        return balanceOfWant();
    }

    // Sells our harvested VELO into the selected output (USDC)
    function _sellVelo(uint256 _veloAmount) internal {
        IVelodromeRouter(velodromeRouter).swapExactTokensForTokens(
            _veloAmount,
            uint256(0),
            veloTokenPath,
            address(this),
            block.timestamp
        );
    }

    function prepareMigration(address _newStrategy) internal override {
        if (!depositerAvoid) {
            // our balance of velodrome lp tokens staked in gauge	
            uint256 staked = balanceOfLPStaked();	
            if (staked > 0) {	
                // Withdraw oxLP from multiRewards	
                gauge.withdraw(staked);	
            }
        }

        uint256 lpBalance = balanceOfLPUnstaked();

        if (lpBalance > 0) {
            IERC20(solidPoolAddress).safeTransfer(_newStrategy, lpBalance);
        }

        uint256 susdBalance = balanceOfSusd();

        if (susdBalance > 0) {
            // send our total balance of woofy to the new strategy
            susd.transfer(_newStrategy, susdBalance);
        }
    }

    // Withdraw velodrome LP token from gauge	
    function manualUnstake(uint256 amount)
        external	
        onlyEmergencyAuthorized	
    {	
        _manualUnstake(amount);
    }

    // Withdraw velodrome LP token from gauge	
    function _manualUnstake(uint256 amount)
        internal	
    {	
        gauge.withdraw(amount);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== SETTERS ========== */

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