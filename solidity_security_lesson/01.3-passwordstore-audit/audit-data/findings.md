### [H-1] Storing the password on-chain makes it visable to anyone, and no longer private 

**Description:** All data stored on-chain is visible to anyone, and can be read directly from blockchain.

**Impact:**  Anyone can read the private password, severly breaking the functionlity of the protocol.

**Proof of Concept:** (Proof of Code) 

The below test case shows how anyone can read the password directly from the blockchain.

1. Create a locally running chain
```bash
make anvil
```
2. Deploy the contract to the chain
```bash
make deploy
```

3. Run the storage tool
We use `1` because that's the storage slot of `s_password` in the contract.
```bash
cast storage <CONTRACT_ADDRESS> 1 --rpc-url http://localhost:8545
```

after this command, you can get this binary data
0x6d7950617373776f726400000000000000000000000000000000000000000014

and then you can get the password by parsing the data
```bash
cast parse-bytes32-string 0x6d7950617373776f726400000000000000000000000000000000000000000014
```

```
output: myPassword
```

**Recommended Mitigation:** 
Encrypt the password off-chain, and then store the encrypted password on-chain.


### [H-2] `PasswordStore::setPassword` has no access controls, meaning a non-owner could change the password function, however, the natspec of the function and overall purpose of the smart contract is that `This function allows only the owner to set a new password.`

**Description:** 
```javascript
    function setPassword(string memory newPassword) external {
        // @audit - There are no access controls
        s_password = newPassword;
        emit SetNetPassword();
    }
```

**Impact:** Anyone can set/change the password of the contract

**Proof of Concept:**
1. Add the following to the `PasswordStore.t.sol`
<details>
<summary>Code</summary>

```javascript
    function test_anyone_can_set_password(address randomAddress) public {
        vm.prank(randomAddress);
        string memory expectedPassword = "myNewPassword";
        passwordStore.setPassword(expectedPassword);

        vm.prank(owner);
        string memory actualPassword = passwordStore.getPassword();
        assertEq(actualPassword, expectedPassword);
    }
```

</details>

**Recommended Mitigation:** Add an access control conditional to the `setPassword` function.

```javascript
    if (msg.sender != s_owner) {
        revert PasswordStore__NotOwner();
    }
```


### [I-1] The `PasswordStore::getPassword` natspec indicates a paramter that doesn't exist, causing the natspec is incorrect

**Description:** 

```javascript
    function getPassword() external view returns (string memory) {
        if (msg.sender != s_owner) {
            revert PasswordStore__NotOwner();
        }
        return s_password;
    }
```

The `PasswordStore:getPassword` function signature is `getPassword()` while the natspec say it should be `getPassword(string)`.

**Impact:** The natspec is incorrect

**Recommended Mitigation:**  Remove the incorrect natspec line.

```diff
-     * @param newPassword The new password to set.
```
