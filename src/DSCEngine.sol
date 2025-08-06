// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/// @title DSCEngine
/// @author Aryan Agarwal
/// Collateral: Exogenous (ETH & BTC)
/// Minting: Algorithmic
/// Relative Stability: Pegged to USD
/// 
/// The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
/// - Exogenous Collateral
/// - Dollar Pegged
/// - Algorithmically Stable

/// It is similar to DAI if DAI had no governance, no fees, and was only backed by wEtH and wBTC

/// Our Dsc system should always be overcollateralized. At no point, should the value of all collateral <=
/// the $ backed value of all the Dsc.

/// @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming
/// DSC, as well as depositing & withdrawing collateral.
/// @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.

contract DSCEngine is ReentrancyGuard {
    //////////////////////////
    /////     Errors     /////
    //////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    ///////////////////////////
    ///// State Variables /////
    ///////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed 
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////
    /////     Events     /////
    //////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    
    /////////////////////////
    /////   Modifiers   /////
    /////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__TokenNotAllowed(token);
            _;
        }
    }

    /////////////////////////
    /////   Functions   /////
    /////////////////////////
    constructor(
        address[] memory tokenAddresses, 
        address[] memory priceFeedAddress,
        address dscAddress
        ) {
            if(tokenAddresses.length != priceFeedAddress.length) {
                revert DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
            }

            for(uint256 i = 0; i < tokenAddresses.length; i++) {
                s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
                s_collateralTokens.push(tokenAddresses[i]);
            }
            i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    /////   External    /////
    /////////////////////////
    function depositCollateralAndMintDsc() external {

    }

    /// @param tokenCollateralAddress The address of the token to deposit as collateral
    /// @param amountCollateral The amount of collateral to deposit
    function despositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    
    function redeemCollateralForDsc() external {

    }

    function redeemCollateral() external {

    }

    // 1. Check if the collateral value > DSC amount. Involves Price Feeds etc.
    /// @param amountDscToMint The amount of decentralized stablecoin to mint
    /// @notice they must have more collateral value than the minimum threshold
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant{
        s_dscMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {

    }

    function liquidate() external {

    }

    function getHealthFactor() external {

    }

    /////////////////////////////////
    /////   Private/Internal    /////
    /////////////////////////////////
    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd){
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /// @notice Returns how close to liquidation a user is
    /// @dev If user goes below 1 they can get liquidated
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // return (collateralValueInusd / totalDscMinted); // 100$ worth collateral and 100 value makes the health factor 1 but we need overcollaterlization
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view{
        //1. checks health factor (do they have enough collateral?)
        //2. revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////
    /////   view Functions    /////
    ///////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd){
        // Take all the tokens which are collateral to the user, get the amounts and map it to the 
        // price to get the usd valud of the collateral.
        for(uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface pricefeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = pricefeed.latestRoundData();
        // 1ETH = 1000$
        // The returned value from Chainlink will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}