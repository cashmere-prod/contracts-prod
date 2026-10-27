// SPDX-License-Identifier: BUSL-1.1
// Modified by Goat for Robinhood Chain: setVault is virtual so that AutoRange can disable it.
// Source: revert-finance/lend@7e85a81 src/transformers/Transformer.sol.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../utils/Constants.sol";
import "../interfaces/IVault.sol";

abstract contract Transformer is Ownable2Step, Constants {
    event VaultSet(address newVault);

    // configurable by owner
    mapping(address => bool) public vaults;

    /**
     * @notice Owner controlled function to activate vault address
     * @param _vault vault
     */
    // Goat: virtual (AutoRange overrides it to disable vaults)
    function setVault(address _vault) external virtual onlyOwner {
        emit VaultSet(_vault);
        vaults[_vault] = true;
    }

    // validates if caller is owner (direct or indirect for a given position)
    function _validateOwner(INonfungiblePositionManager nonfungiblePositionManager, uint256 tokenId, address vault)
        internal
    {
        // vault can not be owner
        if (vaults[msg.sender]) {
            revert Unauthorized();
        }

        address owner;
        if (vault != address(0)) {
            if (!vaults[vault]) {
                revert Unauthorized();
            }
            owner = IVault(vault).ownerOf(tokenId);
        } else {
            owner = nonfungiblePositionManager.ownerOf(tokenId);
        }

        if (owner != msg.sender) {
            revert Unauthorized();
        }
    }

    // validates if caller is allowed to process position
    function _validateCaller(INonfungiblePositionManager nonfungiblePositionManager, uint256 tokenId) internal view {
        if (vaults[msg.sender]) {
            uint256 transformedTokenId = IVault(msg.sender).transformedTokenId();
            if (tokenId != transformedTokenId) {
                revert Unauthorized();
            }
        } else {
            address owner = nonfungiblePositionManager.ownerOf(tokenId);
            if (owner != msg.sender && owner != address(this)) {
                revert Unauthorized();
            }
        }
    }
}
