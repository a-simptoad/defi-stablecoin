// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract DscEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    MockV3Aggregator mockAggregator;

    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // 20,000 USD in value
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC_MINTED = 100 ether;
    uint256 public constant MORE_AMOUNT_DSC_MINTED = 8000 ether;
    uint256 public constant AMOUNT_LIQUID_DSC = 7000 ether;
    int256 public constant LOWER_ETH_PRICE_USD = 1000e8;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);

        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE * 2);

        mockAggregator = MockV3Aggregator(ethUsdPriceFeed);
    }

    //Constructor tests
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // Price tests
    function testGetUsdValue() public view{
        uint256 ethAmount = 15e18;
        // 15e18 * 2000$ 
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    // depositCollateral Tests

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(ranToken)));
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral(address user, uint256 amount) {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amount);
        dscEngine.depositCollateral(weth, amount);
        vm.stopPrank();
        _;
    }

    modifier dscMinted(address user, uint256 amount) {
        vm.prank(user);
        dscEngine.mintDsc(amount);
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral(USER, AMOUNT_COLLATERAL){
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd);
    }
    
    function testGetAccountCollateralValue() public depositedCollateral(USER, AMOUNT_COLLATERAL) {
        // 10 ether in initial deposit
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 expectedCollateral = 30000e18;
        uint256 totalCollateral = dscEngine.getAccountCollateralValue(USER);

        assertEq(totalCollateral, expectedCollateral);
    }

    // burnDsc function

    function testBurnDsc() public depositedCollateral(USER, AMOUNT_COLLATERAL) dscMinted(USER, AMOUNT_DSC_MINTED){
        uint256 expectedDscAfterBurning = 0;

        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dscEngine), AMOUNT_DSC_MINTED);
        dscEngine.burnDsc(AMOUNT_DSC_MINTED);
        (uint256 totalDscMinted, ) = dscEngine.getAccountInformation(USER);
        vm.stopPrank(); 

        assertEq(totalDscMinted, expectedDscAfterBurning);
    }

    // redeem collateral function

    function testRedeemCollateralWorksAndEmitsEvent() public depositedCollateral(USER, AMOUNT_COLLATERAL) {
        uint256 initalBalance = ERC20Mock(weth).balanceOf(USER);

        vm.startPrank(USER);
        vm.expectEmit(true, true, true, false);
        emit DSCEngine.CollateralRedeemed(USER, weth, AMOUNT_COLLATERAL);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 balanceGained = ERC20Mock(weth).balanceOf(USER) - initalBalance;

        assertEq(balanceGained, AMOUNT_COLLATERAL);
    }

    // HealthFactor tests

    function testHealthFactor() public depositedCollateral(USER, AMOUNT_COLLATERAL) dscMinted(USER, AMOUNT_DSC_MINTED){

        // deposited collateral = 10e18
        // minted dsc = 10

        uint256 expectedFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);

        assertEq(healthFactor, expectedFactor);
    }

    function testLiquidateRevertsHealthFactorOk() public depositedCollateral(USER, AMOUNT_COLLATERAL) dscMinted(USER, AMOUNT_DSC_MINTED){
        // In this function we are assuming the health factor is ok hence no change of value of weth
        
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        dsc.approve(address(dscEngine), AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }
    
    function testLiquidate() public depositedCollateral(USER, AMOUNT_COLLATERAL) dscMinted(USER, MORE_AMOUNT_DSC_MINTED) depositedCollateral(LIQUIDATOR, AMOUNT_COLLATERAL * 2) dscMinted(LIQUIDATOR, AMOUNT_LIQUID_DSC) {
        // Collateral is deposited and dsc have been minted for USER
        // 20000 ether collateral (20000 usd), 8000 dsc minted
        // Collateral is deposited for LIQUIDATOR AS WELL (20000 usd)
      
        // Now we need to reduce the value of weth
        mockAggregator.updateAnswer(LOWER_ETH_PRICE_USD);

        // 10000 ether collateral (10000 usd)
        // 8000 ether dsc minted already
        // healthFactor now will be 0.5 ether < (min_health_factor)

        // Then a LIQUIDATOR will try to liquidate the position
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), AMOUNT_LIQUID_DSC);
        dscEngine.liquidate(weth, USER, AMOUNT_LIQUID_DSC);
        vm.stopPrank();

        // Now the user has 20k usd as collateral and 10k usd as dsc tokens
        // The health factor is 10k / 10k usd = 1 ether


    }
}

// MockV3Aggregator instance does not initialize in the test directly but i had to intialize 
// in the setUp function. Why?? 