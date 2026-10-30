// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Ecosystem Fund vesting
/// @notice 100,000 TF, linear over 24 months. No cliff, no early release,
///         no owner, no revocation. Anyone may trigger a release; the tokens
///         always go to the fixed beneficiary.
contract EcosystemVesting {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint64 public immutable start;
    uint256 public immutable total;
    uint64 public constant DURATION = 730 days;

    uint256 public released;

    event Released(address indexed beneficiary, uint256 amount);

    constructor(IERC20 _token, address _beneficiary, uint64 _start, uint256 _total) {
        require(address(_token) != address(0), "token zero");
        require(_beneficiary != address(0), "beneficiary zero");
        require(_total > 0, "total zero");
        token = _token;
        beneficiary = _beneficiary;
        start = _start;
        total = _total;
    }

    function vested() public view returns (uint256) {
        if (block.timestamp <= start) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= DURATION) return total;
        return (total * elapsed) / DURATION;
    }

    function releasable() public view returns (uint256) {
        return vested() - released;
    }

    function release() external {
        uint256 amount = releasable();
        require(amount > 0, "nothing to release");
        released += amount;
        token.safeTransfer(beneficiary, amount);
        emit Released(beneficiary, amount);
    }
}
