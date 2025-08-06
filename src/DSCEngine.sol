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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////////
    ///// State Variables /////
    ///////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDITY_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed 
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////
    /////     Events     /////
    //////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);
    
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
    /*
     *@param tokenCollateralAddress: The address of the token to deposit as collateral
     *@param amountCollateral: Amount of collateral to deposit 
     *@param amountDscToMint: amount of DecentralizedStableCoin to mint
     *@notice: This function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /// @param tokenCollateralAddress The address of the token to deposit as collateral
    /// @param amountCollateral The amount of collateral to deposit
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    
    /*
     *@param tokenCollateralAddress: The address of the token(collateral) to redeem
     *@param amountCollateral: Amount of collateral to redeem 
     *@param amountDscToMint: amount of DecentralizedStableCoin to burn
     *@notice This function burns DSC and redeems underlying collateral in one transaction
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1. Check if the collateral value > DSC amount. Involves Price Feeds etc.
    /// @param amountDscToMint The amount of decentralized stablecoin to mint
    /// @notice they must have more collateral value than the minimum threshold
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_dscMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This revert would never hit as burning tokens would improve the Health factor and hence is removed at auditing
    }

    // I had 100 $ collateral i minted 50 $ dsc, i exchanged 50 $ dsc for another 50 $ collateral, then i minted more dsc??????? But i did not burn any dsc so my health factor is already low. but i added 50 $ collateral so i can now mint 25 $ dsc and so on.. hence i could leverage to some extent and increase the value of my collateral. Dammnnnnn
    /*
     *@param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again
     *This is collateral that you're going to take from the user who is insolvent
     *In return, you have to burn your DSC to pay off their debt, but you don't pay off your own
     *@param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     *@param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we would'nt be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor > MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDITY_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralRedeemed, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
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
    
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This Conditional is hypothetically unreachable
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
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

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // No. of decimals returned from Chainlink are 8 hence we multiply by 1e10
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}