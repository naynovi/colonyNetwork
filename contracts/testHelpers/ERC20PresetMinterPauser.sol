// SPDX-License-Identifier: MIT
// Generated by https://wizard.openzeppelin.com/, which the old ERC20PresetMinterPauser.sol
// in openzeppelin-solidity / openzeppelin-contracts was deprecated in favour of.
pragma solidity 0.8.23;

import { ERC20 } from "../../node_modules/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "../../node_modules/@openzeppelin/contracts/security/Pausable.sol";
import { AccessControl } from "../../node_modules/@openzeppelin/contracts/access/AccessControl.sol";

contract ERC20PresetMinterPauser is ERC20, Pausable, AccessControl {
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(PAUSER_ROLE, msg.sender);
    _grantRole(MINTER_ROLE, msg.sender);
  }

  function pause() public onlyRole(PAUSER_ROLE) {
    _pause();
  }

  function unpause() public onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
    _mint(to, amount);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override whenNotPaused {
    super._beforeTokenTransfer(from, to, amount);
  }
}
