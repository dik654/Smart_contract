---
title: Protocol Audit Report
author: dae ik kim 
date: March 7, 2023
header-includes:
  - \usepackage{titling}
  - \usepackage{graphicx}
---

\begin{titlepage}
    \centering
    \begin{figure}[h]
        \centering
        \includegraphics[width=0.5\textwidth]{logo.pdf} 
    \end{figure}
    \vspace*{2cm}
    {\Huge\bfseries Protocol Audit Report\par}
    \vspace{1cm}
    {\Large Version 1.0\par}
    \vspace{2cm}
    {\Large\itshape github.com/dik654\par}
    \vfill
    {\large \today\par}
\end{titlepage}

\maketitle

<!-- Your report starts here! -->

Prepared by: [dik654](https://github.com/dik654)
Lead Auditors: 
- dae ik kim

# Table of Contents
- [Table of Contents](#table-of-contents)
- [Protocol Summary](#protocol-summary)
- [Disclaimer](#disclaimer)
- [Risk Classification](#risk-classification)
- [Audit Details](#audit-details)
  - [Scope](#scope)
  - [Roles](#roles)
- [Executive Summary](#executive-summary)
  - [Issues found](#issues-found)
- [Findings](#findings)
  - [High](#high)
    - [\[H-1\] Storing the password on-chain makes it visable to anyone, and no longer private](#h-1-storing-the-password-on-chain-makes-it-visable-to-anyone-and-no-longer-private)
    - [\[H-2\] `PasswordStore::setPassword` has no access controls, meaning a non-owner could change the password function, however, the natspec of the function and overall purpose of the smart contract is that `This function allows only the owner to set a new password.`](#h-2-passwordstoresetpassword-has-no-access-controls-meaning-a-non-owner-could-change-the-password-function-however-the-natspec-of-the-function-and-overall-purpose-of-the-smart-contract-is-that-this-function-allows-only-the-owner-to-set-a-new-password)
  - [Informational](#informational)
    - [\[I-1\] The `PasswordStore::getPassword` natspec indicates a paramter that doesn't exist, causing the natspec is incorrect](#i-1-the-passwordstoregetpassword-natspec-indicates-a-paramter-that-doesnt-exist-causing-the-natspec-is-incorrect)
  - [Gas](#gas)

# Protocol Summary

Protocol does X, Y, Z

# Disclaimer

The YOUR_NAME_HERE team makes all effort to find as many vulnerabilities in the code in the given time period, but holds no responsibilities for the findings provided in this document. A security audit by the team is not an endorsement of the underlying business or product. The audit was time-boxed and the review of the code was solely on the security aspects of the Solidity implementation of the contracts.

# Risk Classification

|            |        | Impact |        |     |
| ---------- | ------ | ------ | ------ | --- |
|            |        | High   | Medium | Low |
|            | High   | H      | H/M    | M   |
| Likelihood | Medium | H/M    | M      | M/L |
|            | Low    | M      | M/L    | L   |

We use the [CodeHawks](https://docs.codehawks.com/hawks-auditors/how-to-evaluate-a-finding-severity) severity matrix to determine severity. See the documentation for more details.

# Audit Details 

**The findings described in this document correspond the following commit hash:**
```
7d55682ddc4301a7b13ae9413095feffd9924566
```

## Scope 

```
./src/
PasswordStore.sol
```

## Roles

Owner: The user who can set the password and read the password.
Outsides: No one else should be able to set or read the password.

# Executive Summary

*Add some notes about how the audit

## Issues found

| Severtity | Number of issues found |
| --------- | ---------------------- |
| High      | 2                      |
| Meidum    | 0                      |
| Low       | 0                      |
| Info      | 1                      |
| Total     | 3                      |

# Findings
## High

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

## Informational

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


## Gas 