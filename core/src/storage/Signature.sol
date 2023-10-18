/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

library Signature {

    bytes32 internal constant EIP712_REVISION_HASH = keccak256('1');

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
    keccak256(
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
    );

    error SignatureInvalid();

    error SignatureExpired();


    /**
    * @notice A struct containing the necessary information to reconstruct an EIP-712 typed data signature.
     *
     * @param v The signature's recovery parameter.
     * @param r The signature's r parameter.
     * @param s The signature's s parameter
     * @param deadline The signature's deadline
     */
    struct EIP712Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 deadline;
    }


    struct Data {
        mapping(address => uint256) sigNonces;
    }


    /**
     * @dev Wrapper for ecrecover to reduce code size, used in meta-tx specific functions.
     */
    function validateRecoveredAddress(
        bytes32 digest,
        address expectedAddress,
        EIP712Signature calldata sig
    ) internal view {
        if (sig.deadline < block.timestamp) revert SignatureExpired();
        address recoveredAddress = ecrecover(digest, sig.v, sig.r, sig.s);
        if (recoveredAddress == address(0) || recoveredAddress != expectedAddress)
            revert SignatureInvalid();
    }

    /**
     * @dev Calculates EIP712 digest based on the current DOMAIN_SEPARATOR.
     *
     * @param hashedMessage The message hash from which the digest should be calculated.
     *
     * @return bytes32 A 32-byte output representing the EIP712 digest.
     */
    function calculateDigest(bytes32 hashedMessage) private view returns (bytes32) {
        bytes32 digest;
        unchecked {
            digest = keccak256(
                abi.encodePacked('\x19\x01', calculateDomainSeparator(), hashedMessage)
            );
        }
        return digest;
    }

    /**
     * @dev Calculates EIP712 DOMAIN_SEPARATOR based on the current contract and chain ID.
     */
    function calculateDomainSeparator() private view returns (bytes32) {
        return
        keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Reya")),
                EIP712_REVISION_HASH,
                block.chainid,
                address(this)
            )
        );
    }



}