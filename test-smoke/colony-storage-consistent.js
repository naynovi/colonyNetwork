/* global artifacts */
const chai = require("chai");
const bnChai = require("bn-chai");
const BN = require("bn.js");

const { UINT256_MAX, WAD, GLOBAL_SKILL_ID } = require("../helpers/constants");
const { fundColonyWithTokens, setupColony } = require("../helpers/test-data-generator");

const { expect } = chai;
chai.use(bnChai(web3.utils.BN));

const EtherRouter = artifacts.require("EtherRouter");
const IColonyNetwork = artifacts.require("IColonyNetwork");
const IMetaColony = artifacts.require("IMetaColony");
const Token = artifacts.require("Token");
const TokenAuthority = artifacts.require("TokenAuthority");
const ContractEditing = artifacts.require("ContractEditing");
const Resolver = artifacts.require("Resolver");

contract("Contract Storage", (accounts) => {
  const SLOT0 = 0;

  const RECIPIENT = accounts[3];
  const ADMIN = accounts[4];
  const ARBITRATOR = accounts[5];

  let colony;
  let token;
  let otherToken;
  let colonyNetwork;
  let metaColony;
  let domain1;
  let tokenLockingAddress;

  before(async () => {
    // We use our own providers for these test(s) so we can really get in to it...

    const etherRouter = await EtherRouter.deployed();
    colonyNetwork = await IColonyNetwork.at(etherRouter.address);
    const metaColonyAddress = await colonyNetwork.getMetaColony();
    metaColony = await IMetaColony.at(metaColonyAddress);

    token = await Token.new("name", "symbol", 18);
    await token.unlock();
    colony = await setupColony(colonyNetwork, token.address);
    tokenLockingAddress = await colonyNetwork.getTokenLocking();
    const tokenAuthority = await TokenAuthority.new(token.address, colony.address, [tokenLockingAddress]);
    await token.setAuthority(tokenAuthority.address);

    await colony.setRewardInverse(100);
    await colony.setAdministrationRole(1, UINT256_MAX, ADMIN, 1, true);
    await colony.setArbitrationRole(1, UINT256_MAX, ARBITRATOR, 1, true);
    await fundColonyWithTokens(colony, token, UINT256_MAX);
    domain1 = await colony.getDomain(1);

    otherToken = await Token.new("otherName", "otherSymbol", 18);
    await otherToken.unlock();
    await fundColonyWithTokens(colony, otherToken, UINT256_MAX);
  });

  function getAddressStateHash(address) {
    return new Promise((resolve, reject) => {
      web3.currentProvider
        .request({ method: "eth_getProof", params: [address, [], "latest"] })
        .then((result) => {
          return resolve(result.storageHash);
        })
        .catch((e) => {
          reject(e);
        });
    });
  }

  describe("Smoke tests to check our storage layout does not change", () => {
    // There are many things you could do that one would expect to change these hashes. If you've made changes that change the contents of storage of a
    // contract, then these hashes will change. This could include adding an extra transaction somewhere, which could cause the address a contract is
    // deployed to change, which if it is stored somewhere would cause the state hash of the storage to change.

    // If you haven't touched the contracts, however, and this test fails, then something is afoot.
    // In theory, the storage slots used by solidity could change in an upgrade,
    // which this test was written with in mind to try and detect. They don't guarantee this hasn't happened if they pass, but if they fail without just
    // cause then we need to think very carefully about what's going on.

    it("storage contents should be as expected", async () => {
      await colony.makeExpenditure(1, UINT256_MAX, 1, { from: ADMIN });
      const expenditureId = await colony.getExpenditureCount();

      await colony.setExpenditureRecipient(expenditureId, SLOT0, RECIPIENT, { from: ADMIN });
      await colony.setExpenditurePayout(expenditureId, SLOT0, token.address, WAD, { from: ADMIN });
      await colony.setExpenditureSkill(expenditureId, SLOT0, GLOBAL_SKILL_ID, { from: ADMIN });

      const expenditure = await colony.getExpenditure(expenditureId);
      await colony.moveFundsBetweenPots(1, UINT256_MAX, UINT256_MAX, domain1.fundingPotId, expenditure.fundingPotId, WAD, token.address);
      await colony.finalizeExpenditure(expenditureId, { from: ADMIN });
      await colony.claimExpenditurePayout(expenditureId, SLOT0, token.address);

      const miningCycleAddress = await colonyNetwork.getReputationMiningCycle(false);
      const miningCycleStateHash = await getAddressStateHash(miningCycleAddress);

      // For this test to be reproducible, have to zero timestamps / time depenedent things
      // For colonyNetwork, that means the mining staking timestamp

      const contractEditing = await ContractEditing.new();
      const networkAsER = await EtherRouter.at(colonyNetwork.address);
      const colonyNetworkResolverAddress = await networkAsER.resolver();
      const colonyNetworkResolver = await Resolver.at(colonyNetworkResolverAddress);
      await colonyNetworkResolver.register("setStorageSlot(uint256,bytes32)", contractEditing.address);
      const editableNetwork = await ContractEditing.at(colonyNetwork.address);

      // Following
      // https://solidity.readthedocs.io/en/v0.6.8/internals/layout_in_storage.html#mappings-and-dynamic-arrays
      // This is the hash of the key (the address) and the storage slot containing the mapping (33)
      let hashable = `0x000000000000000000000000${accounts[5].slice(2)}${new BN(33).toString(16, 64)}`;
      let hashed = web3.utils.soliditySha3(hashable);
      let slot = new BN(hashed.slice(2), 16);
      // To get the slot containing the timestamp of the miner submission, we add one to where the struct starts
      // (see ColonyNetworkDataTypes)
      slot = slot.addn(1);

      await editableNetwork.setStorageSlot(slot, "0x0000000000000000000000000000000000000000000000000000000000000000");

      // Also zero out the slot containing the current colony version
      await editableNetwork.setStorageSlot(7, "0x0000000000000000000000000000000000000000000000000000000000000000");

      const colonyNetworkStateHash = await getAddressStateHash(colonyNetwork.address);

      // We did a whole expenditure above, so let's take out the finalized timestamp
      // This is the hash of the expenditure id (1) with the storage slot (25) to find the location of the struct
      hashable = `0x${new BN(1).toString(16, 64)}${new BN(25).toString(16, 64)}`;
      hashed = web3.utils.soliditySha3(hashable);
      slot = new BN(hashed.slice(2), 16);
      // To find the slot storing the timestamp, we add three to where the struct starts (see ColonyDataTypes).
      slot = slot.addn(3);

      const colonyAsER = await EtherRouter.at(colony.address);
      const colonyResolverAddress = await colonyAsER.resolver();
      const colonyResolver = await Resolver.at(colonyResolverAddress);
      await colonyResolver.register("setStorageSlot(uint256,bytes32)", contractEditing.address);
      const editableColony = await ContractEditing.at(colony.address);
      await editableColony.setStorageSlot(slot, "0x0000000000000000000000000000000000000000000000000000000000000000");

      const colonyStateHash = await getAddressStateHash(colony.address);
      const metaColonyStateHash = await getAddressStateHash(metaColony.address);
      const tokenLockingStateHash = await getAddressStateHash(tokenLockingAddress);

      console.log("colonyNetworkStateHash:", colonyNetworkStateHash);
      console.log("colonyStateHash:", colonyStateHash);
      console.log("metaColonyStateHash:", metaColonyStateHash);
      console.log("miningCycleStateHash:", miningCycleStateHash);
      console.log("tokenLockingStateHash:", tokenLockingStateHash);

      // TODO: Did we expect these to change?
      expect(colonyNetworkStateHash).to.equal("0xf2b1cb7b422e7d010e16e537de363210eec8c3c4c9e3ab19a781ac25ece12f06");
      expect(colonyStateHash).to.equal("0x56b2f80d1236ff349e183c5a1f9f2ca08046b53b7157aaa7151ea330e8ab090b");
      expect(metaColonyStateHash).to.equal("0xc8dfdb65f1446922ff7dc0a3e011749a77bdd5bf49782e30a63add2819a000a5");
      expect(miningCycleStateHash).to.equal("0xe25607dc8be68653ff0940fcf473e002d3c76ad919eec835385998a134965de2");
      expect(tokenLockingStateHash).to.equal("0xdb8e1ec03a6d80cfaa89d150d347af0ec39502d8eeb46c6809deeb0554e5aa1f");
    });
  });
});
