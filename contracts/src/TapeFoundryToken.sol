// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title TapeFoundry TF
/// @notice Fixed-supply BEP-20. No mint after deployment, no transfer tax,
///         no owner and no blacklist. 90% is minted to the mining reserve,
///         10% to the Ecosystem Fund vesting contract.
contract TapeFoundryToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;
    uint256 public constant MINING_ALLOCATION = 900_000 ether;
    uint256 public constant ECOSYSTEM_ALLOCATION = 100_000 ether;

    constructor(address miningReserve, address ecosystemVesting)
        ERC20("TapeFoundry", "TF")
    {
        require(miningReserve != address(0), "mining reserve zero");
        require(ecosystemVesting != address(0), "ecosystem zero");
        _mint(miningReserve, MINING_ALLOCATION);
        _mint(ecosystemVesting, ECOSYSTEM_ALLOCATION);
    }
}
