// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

//contract to swap woofy for yfi. 1-1
contract OTCTrader is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address internal constant yfi = 0x29b0Da86e484E1C0029B56e817912d778aC0EC69;
    address internal constant woofy = 0xD0660cD418a64a1d44E9214ad8e459324D8157f1;
    mapping(address => uint256) public deposits; // amount of liquidity user has provided
    mapping(address => bool) public traders; // allow us to limit traders


    constructor() public {
        traders[msg.sender] = true;
    }

    function setTradePermission(address _trader, bool _allowed)
        external
        onlyOwner
    {
        traders[_trader] = _allowed;
    }

    //trade between yfi and woofy at 1-1
    function trade(address _tokenIn, uint256 _amount) public tradersonly {
        require(_tokenIn == yfi || _tokenIn == woofy, "token not allowed");

        IERC20 tokenOut = _tokenIn == yfi ? IERC20(woofy) : IERC20(yfi);
        IERC20 tokenIn = IERC20(_tokenIn);

        uint256 balanceOfOut = tokenOut.balanceOf(address(this));

        require(balanceOfOut >= _amount, "not enough liquidity");

        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 diff = tokenIn.balanceOf(address(this)).sub(balanceBefore);
        require(diff >= _amount);

        tokenOut.safeTransfer(msg.sender, _amount);
    }

    //provide liquidity with yfi or woofy. treated as the same
    function provideLiquidity(address _token, uint256 _amount) public tradersonly {
        require(_token == yfi || _token == woofy, "token not allowed");
        deposits[msg.sender] = deposits[msg.sender].add(_amount);
        IERC20 token = IERC20(_token);

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 diff = token.balanceOf(address(this)).sub(balanceBefore);

        require(diff >= _amount);
        
    }

    function withdrawLiquidity(address _token, uint256 _amount) public tradersonly {
        require(_token == yfi || _token == woofy, "token not allowed");
        uint256 deposited = deposits[msg.sender];
        deposits[msg.sender] = deposited.sub(_amount);

        IERC20 token = IERC20(_token);

        uint256 balanceBefore = token.balanceOf(address(this));

        require(balanceBefore >= _amount, "not enough liquidity");
        
        require(deposited >= _amount, "not enough deposits");

        token.safeTransfer(msg.sender, _amount);

        
    }

    modifier tradersonly() {

        require(traders[msg.sender], "traders only");
   

        _;
    }
}
