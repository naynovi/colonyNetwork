/* globals artifacts ColonyNetwork, Colony, IColony, Resolver */
import sha3 from 'solidity-sha3';
import testHelper from '../helpers/test-helper';
const upgradableContracts = require('../helpers/upgradable-contracts');

const ColonyNetwork = artifacts.require('ColonyNetwork');
const Colony = artifacts.require('Colony');
const IColony = artifacts.require('IColony');
const Resolver = artifacts.require('Resolver');

contract('ColonyNetwork', function (accounts) {
  const COLONY_KEY = 'COLONY_TEST';
  const MAIN_ACCOUNT = accounts[0];
  const OTHER_ACCOUNT = accounts[1];
  let colony;
  let resolver;
  let colonyNetwork;
  let createColonyGas;
  let version;

  before(async function () {
    createColonyGas = (web3.version.network == 'coverage') ? '0xfffffffffff' : 4e6;
  });

  beforeEach(async function () {
    colony = await Colony.new();
    version = await colony.version.call();
    resolver = await Resolver.new();
    colonyNetwork = await ColonyNetwork.new();
    await upgradableContracts.setupColonyVersionResolver(colony, resolver, colonyNetwork);
  });

  describe('when initialised', () => {
    it('should accept ether', async function () {
      await colonyNetwork.send(1);
      let colonyNetworkBalance = web3.eth.getBalance(colonyNetwork.address);
      assert.equal(colonyNetworkBalance.toNumber(), 1);
    });

    it('should have the correct current Colony version set', async function () {
      const currentColonyVersion = await colonyNetwork.currentColonyVersion.call();
      assert.equal(version.toNumber(), currentColonyVersion.toNumber());
    });

    it('should have the Resolver for current Colony version set', async function () {
      const currentResolver = await colonyNetwork.colonyVersionResolver.call(version.toNumber());
      assert.equal(currentResolver, resolver.address);
    });
  });

  describe('when creating new colonies', () => {
    it('should allow users to create new colonies', async function () {
      await colonyNetwork.createColony(COLONY_KEY);
      const address = await colonyNetwork.getColony(COLONY_KEY);
      const countColonies = await colonyNetwork.countColonies.call();
      assert.equal(countColonies.toNumber(), 1);
    });

    it('should maintain correct count of colonies', async function () {
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      await colonyNetwork.createColony(testHelper.getRandomString(7));
      const countColonies = await colonyNetwork.countColonies.call();
      assert.equal(countColonies.toNumber(), 7);
    });

    it('should allow users to get the address of a colony by its index', async function () {
      await colonyNetwork.createColony('Colony1');
      await colonyNetwork.createColony('Colony2');
      await colonyNetwork.createColony('Colony3');
      const colonyAddress = await colonyNetwork.getColonyAt.call(3);
      assert.notEqual(colonyAddress, '0x0000000000000000000000000000000000000000');
    });

    it('should return an empty address if there is no colony for the index provided', async function () {
      const colonyAddress = await colonyNetwork.getColonyAt.call(15);
      assert.equal(colonyAddress, '0x0000000000000000000000000000000000000000');
    });

    it('should be able to get the Colony version', async function () {
      await colonyNetwork.createColony(COLONY_KEY);
      const colonyAddress = await colonyNetwork.getColony.call(COLONY_KEY);
      colony = await Colony.at(colonyAddress);
      const actualColonyVersion = await colony.version.call();
      assert.equal(version.toNumber(), actualColonyVersion.toNumber());
    });

    it('should fail if ETH is sent', async function () {
      let tx;
      try {
        tx = await colonyNetwork.createColony(COLONY_KEY, { value: 1, gas: createColonyGas });
      } catch (err) {
        tx = testHelper.checkErrorNonPayableFunction(err);
      }
      let colonyNetworkBalance = web3.eth.getBalance(colonyNetwork.address);
      assert.equal(0, colonyNetworkBalance.toNumber());
    });
  });
});