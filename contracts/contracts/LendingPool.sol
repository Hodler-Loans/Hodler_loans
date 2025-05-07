// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

//TODO: Price oracle should use uniswap pool
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract LendingPool is Ownable {
    IERC20 public collateralToken;
    IERC20 public loanToken;
    IPriceOracle public priceOracle;

    uint256 public collateralFactor = 150; // 150%
    uint256 public liquidationThreshold = 120; // 120%
    uint256 public interestRate = 5; // 5% flat interest
    uint256 public loanDuration = 7 days;

    uint256 public totalDeposits; // loanToken liquidity provided by lenders
    uint256 public totalBorrows;
    uint256 public totalYield; // earned yield to be shared among lenders

    uint256 public adminFeePercent = 10; // 10% of yield goes to admin
    uint256 public adminFeesAccrued;

    mapping(address => uint256) public lenderBalances;

    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 interestOwed;
        uint256 borrowTimestamp; // new field to track time of borrowing
    }

    mapping(address => Position) public positions;

    constructor(address _collateralToken, address _loanToken, address _oracle) {
        collateralToken = IERC20(_collateralToken);
        loanToken = IERC20(_loanToken);
        priceOracle = IPriceOracle(_oracle);
    }

    // ========== LENDER FUNCTIONS ==========

    function depositLoanToken(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        loanToken.transferFrom(msg.sender, address(this), amount);
        lenderBalances[msg.sender] += amount;
        totalDeposits += amount;
    }

    function withdrawLoanToken(uint256 amount) external {
        require(lenderBalances[msg.sender] >= amount, "Insufficient balance");

        uint256 poolAvailable = getAvailableLiquidity();
        require(poolAvailable >= amount, "Insufficient liquidity");

        lenderBalances[msg.sender] -= amount;
        totalDeposits -= amount;
        loanToken.transfer(msg.sender, amount);
    }

    function claimYield() external {
        uint256 share = (lenderBalances[msg.sender] * totalYield) /
            totalDeposits;
        totalYield -= share;
        loanToken.transfer(msg.sender, share);
    }

    // ========== BORROWER FUNCTIONS ==========

    function depositCollateral(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        collateralToken.transferFrom(msg.sender, address(this), amount);
        positions[msg.sender].collateralAmount += amount;
    }

    function borrow(uint256 amount) external {
        require(amount > 0, "Invalid borrow amount");

        Position storage pos = positions[msg.sender];
        uint256 newDebt = pos.debtAmount + amount;
        uint256 collateralValue = _getValue(
            collateralToken,
            pos.collateralAmount
        );

        require(
            (collateralValue * 100) / newDebt >= collateralFactor,
            "Not enough collateral"
        );
        require(getAvailableLiquidity() >= amount, "Not enough liquidity");

        uint256 interest = (amount * interestRate) / 100;
        pos.debtAmount = newDebt;
        pos.interestOwed += interest;
        pos.borrowTimestamp = block.timestamp; // ⏱ Start tracking time
        totalBorrows += amount;

        loanToken.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        require(amount > 0, "Invalid repayment");
        require(pos.debtAmount + pos.interestOwed >= amount, "Overpaying");

        loanToken.transferFrom(msg.sender, address(this), amount);

        uint256 remaining = amount;

        // Pay interest first
        if (pos.interestOwed > 0) {
            uint256 payInterest = remaining > pos.interestOwed
                ? pos.interestOwed
                : remaining;
            pos.interestOwed -= payInterest;

            uint256 adminCut = (payInterest * adminFeePercent) / 100;
            adminFeesAccrued += adminCut;
            totalYield += (payInterest - adminCut);

            remaining -= payInterest;
        }

        if (remaining > 0) {
            pos.debtAmount -= remaining;
            totalBorrows -= remaining;
        }
    }

    function withdrawCollateral(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        require(amount > 0 && amount <= pos.collateralAmount, "Invalid amount");

        uint256 newCollateral = pos.collateralAmount - amount;
        uint256 newCollateralUSD = _getValue(collateralToken, newCollateral);
        uint256 totalDebt = pos.debtAmount + pos.interestOwed;

        require(
            totalDebt == 0 ||
                (newCollateralUSD * 100) / totalDebt >= collateralFactor,
            "Undercollateralized"
        );

        pos.collateralAmount = newCollateral;
        collateralToken.transfer(msg.sender, amount);
    }

    // ========== LIQUIDATION ==========

    function liquidate(address borrower) external {
        Position storage pos = positions[borrower];
        require(pos.debtAmount > 0, "No debt");

        uint256 collateralUSD = _getValue(
            collateralToken,
            pos.collateralAmount
        );
        uint256 totalDebt = pos.debtAmount + pos.interestOwed;
        uint256 debtUSD = _getValue(loanToken, totalDebt);

        bool isExpired = block.timestamp > pos.borrowTimestamp + loanDuration;
        bool isUnderwater = (collateralUSD * 100) / debtUSD <
            liquidationThreshold;

        require(isUnderwater || isExpired, "Not liquidatable");

        uint256 recoveredLoanToken = _getValue(
            collateralToken,
            pos.collateralAmount
        );

        if (recoveredLoanToken > totalDebt) {
            uint256 excess = recoveredLoanToken - totalDebt;
            uint256 adminCut = (excess * adminFeePercent) / 100;
            adminFeesAccrued += adminCut;
            totalYield += (excess - adminCut);
        }

        totalBorrows -= pos.debtAmount;
        pos.collateralAmount = 0;
        pos.debtAmount = 0;
        pos.interestOwed = 0;
        pos.borrowTimestamp = 0;

        loanToken.transfer(msg.sender, totalDebt); // reward liquidator
    }

    // ========== VIEW FUNCTIONS ==========

    function getAvailableLiquidity() public view returns (uint256) {
        return totalDeposits - totalBorrows;
    }

    function _getValue(
        IERC20 token,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 price = priceOracle.getPrice(address(token));
        return (amount * price) / 1e18;
    }

    // Admin setters
    function setCollateralFactor(uint256 factor) external onlyOwner {
        require(factor >= 100, "Must be >= 100%");
        collateralFactor = factor;
    }

    function setLiquidationThreshold(uint256 threshold) external onlyOwner {
        require(threshold >= 100, "Must be >= 100%");
        liquidationThreshold = threshold;
    }

    function setInterestRate(uint256 rate) external onlyOwner {
        interestRate = rate;
    }

    function setLoanDuration(uint256 duration) external onlyOwner {
        require(duration >= 1 days, "Too short");
        loanDuration = duration;
    }

    function setAdminFeePercent(uint256 percent) external onlyOwner {
        require(percent <= 50, "Too high");
        adminFeePercent = percent;
    }

    function withdrawAdminFees(address to) external onlyOwner {
        require(adminFeesAccrued > 0, "No fees");
        uint256 amount = adminFeesAccrued;
        adminFeesAccrued = 0;
        loanToken.transfer(to, amount);
    }

    function getYieldBreakdown(
        address lender
    )
        external
        view
        returns (
            uint256 totalYieldPool,
            uint256 adminFees,
            uint256 lenderShare,
            uint256 lenderPercent
        )
    {
        totalYieldPool = totalYield;
        adminFees = adminFeesAccrued;

        if (totalDeposits == 0) {
            lenderShare = 0;
            lenderPercent = 0;
        } else {
            lenderShare =
                (lenderBalances[lender] * totalYieldPool) /
                totalDeposits;
            lenderPercent = (lenderBalances[lender] * 10000) / totalDeposits; // in basis points
        }
    }

    function getUserPosition(
        address user
    )
        external
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 interestOwed,
            uint256 collateralValue,
            uint256 debtValue,
            uint256 healthFactor,
            bool isLiquidatable
        )
    {
        Position storage pos = positions[user];
        collateral = pos.collateralAmount;
        debt = pos.debtAmount;
        interestOwed = pos.interestOwed;

        collateralValue = _getValue(collateralToken, collateral);
        debtValue = _getValue(loanToken, debt + interestOwed);

        healthFactor = debtValue > 0
            ? (collateralValue * 10000) / debtValue
            : type(uint256).max;

        bool belowThreshold = (collateralValue * 100) / debtValue <
            liquidationThreshold;
        bool expired = pos.borrowTimestamp > 0 &&
            block.timestamp > pos.borrowTimestamp + loanDuration;

        isLiquidatable = debt > 0 && (belowThreshold || expired);
    }

    function getUserDashboard(
        address user
    )
        external
        view
        returns (
            // Borrower data
            uint256 collateral,
            uint256 debt,
            uint256 interestOwed,
            uint256 collateralValue,
            uint256 debtValue,
            uint256 healthFactor,
            bool isLiquidatable,
            // Lender data
            uint256 lenderBalance,
            uint256 lenderPercent,
            uint256 claimableYield,
            // Admin stats
            uint256 totalYieldPool,
            uint256 adminFees
        )
    {
        //     📌 Example Output
        // Category	Field	Example
        // Borrower	collateral	10e18 COL
        // debt	500e18 DAI
        // collateralValue	$1000
        // debtValue	$525
        // healthFactor	19000 = 190%
        // isLiquidatable	false
        // Lender	lenderBalance	3000e18 DAI
        // lenderPercent	6000 (60%)
        // claimableYield	15e18 DAI
        // Admin	totalYieldPool	25e18
        // adminFees	2.5e18
        Position storage pos = positions[user];

        // Borrower values
        collateral = pos.collateralAmount;
        debt = pos.debtAmount;
        interestOwed = pos.interestOwed;
        collateralValue = _getValue(collateralToken, collateral);
        debtValue = _getValue(loanToken, debt + interestOwed);
        healthFactor = debtValue > 0
            ? (collateralValue * 10000) / debtValue
            : type(uint256).max;

        bool belowThreshold = (collateralValue * 100) / debtValue <
            liquidationThreshold;
        bool expired = pos.borrowTimestamp > 0 &&
            block.timestamp > pos.borrowTimestamp + loanDuration;
        isLiquidatable = debt > 0 && (belowThreshold || expired);

        // Lender values
        lenderBalance = lenderBalances[user];
        if (totalDeposits > 0) {
            lenderPercent = (lenderBalance * 10000) / totalDeposits;
            claimableYield = (lenderBalance * totalYield) / totalDeposits;
        }

        // Admin values
        totalYieldPool = totalYield;
        adminFees = adminFeesAccrued;
    }
}

// TEST EXAMPLE: simulate timeout
// await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]); // 8 days
// await ethers.provider.send("evm_mine");

// await lendingPool.connect(liquidator).liquidate(borrower.address); // should succeed due to timeout

