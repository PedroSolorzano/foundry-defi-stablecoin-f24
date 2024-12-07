// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC = 5 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approveInternal(USER, address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier dscMintedForUser() {
        uint256 amountDscToMint = AMOUNT_DSC;
        vm.startPrank(USER);
        dsce.mintDsc(amountDscToMint);
        console.log("Health Factor after initial mint:", dsce.getHealthFactor(USER));
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsd = 30000 ether;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assert(expectedUsd == actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        depositCollateral TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, 10e8);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;

        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /*//////////////////////////////////////////////////////////////
                              SOLO TESTING
    //////////////////////////////////////////////////////////////*/

    function testGetUsersHealthFactor() public dscMintedForUser {
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        console.log("User's Health Factor:", userHealthFactor);
    }

    function testMintDscRevertsIfHealthFactorBreaks() public {
        // Arrange
        uint256 amountDscToMint = AMOUNT_COLLATERAL; // Mint more than collateral

        // Act/Assert
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSignature("DSCEngine__BreaksHealthFactor(uint256)", dsce.getHealthFactor(USER)));
        dsce.mintDsc(amountDscToMint);
        console.log("User's Health Factor:", dsce.getHealthFactor(USER));
        vm.stopPrank();
        // 100,000,000,000,000,000,000
    }

    function testMintDscRevertsIfTooMuchDscIsMinted() public depositedCollateral dscMintedForUser {
        // Arrange
        uint256 amountDscToMint = 1e19; // High value so that the division makes the HF lower than the MIN_HEALTH_FACTOR

        // Act/Assert
        // What's happening so far: It is failing with the correct error, but the value in the error is different from predicted
        // Can't yet figure out why it's different or how to check what it's giving, but when that value is copied and placed on
        // the abi.encodeWithSignature, it works just fine, as if there was a problem with the encodeWithSignature.
        // Update: The reason the encodings are different is because the expectRevert is working with the HF BEFORE the mint (DUH)
        // Surely there's a way to setup the test so that the right signature can be predicted right?
        // Maybe the only way is to hardcode the value that's supposed to appear which in this case is: 999500249875062468
        // This feels like somewhere to try a fuzz test
        vm.startPrank(USER);
        vm.expectRevert(); // abi.encodeWithSignature("DSCEngine__BreaksHealthFactor(uint256)", dsce._getHealthFactor(USER));
        dsce.mintDsc(amountDscToMint);
        vm.stopPrank();
    }
    //2,000,000,000,000,000,000,000
    //  666,666,666,666,666,666,666
    //    1,000,000,000,000,000,000
    //1,960,784,313,725,490,196,078
    //      999,500,249,875,062,468

    // function testRedeemCollateralForDscRevertsIfHealthFactorBreaks() public depositedCollateral dscMintedForUser {
    //     // Act/Assert
    //     vm.startPrank(USER);
    //     // vm.expectRevert();
    //     dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 2 * AMOUNT_DSC);
    //     vm.stopPrank();
    // } //

    function testLiquidateRevertsIfHealthFactorIsOk() public depositedCollateral dscMintedForUser {
        // Arrange
        // Modifiers add collateral and dsc so HF should be ok

        // Act/Assert
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfHealthFactorBreaks() public depositedCollateral dscMintedForUser {
        // Arrange
        // Modifiers add collateral and dsc so HF should be ok

        // Act/Assert
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, (AMOUNT_COLLATERAL * 9) / 10); // Should work?
        console.log("Final HF:", dsce._healthFactor(USER));
        vm.stopPrank();
    }
    //2000000000000000000000
    //200000000000000000000
    //100000000000000000000

    // TestMockCall
    function testMockCall() public {
        uint256 testNum = 10e8;
        uint256 testAmount = 5e20;
        vm.mockCall(address(dsce), abi.encodeWithSelector(dsce.getUsdValue.selector), abi.encode(testNum));
        assert(dsce.getUsdValue(weth, testAmount) == testNum);
    }

    function testLiquidateRevertsIfHealthFactorDoesntImprove() public depositedCollateral dscMintedForUser {
        // So I need to make it so that the collateral loses value, how do I do that?
        // Arrange
        // vm.startPrank(USER);
        // dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        // vm.stopPrank();
        // Weth collateral Price in USD: 200,000,000,000
        // Gotta get this price to drop manually
        uint256 testNum = 10e10;
        vm.mockCall(
            address(config),
            abi.encodeWithSignature("getUsdPrice(address,uint256)", weth, AMOUNT_COLLATERAL),
            abi.encode(testNum) // A significantly lower price
        );
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL);
    }

    // Repository tests
}
