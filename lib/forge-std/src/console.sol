// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

library console {
    address constant CONSOLE_ADDRESS = 0x000000000000000000636F6e736F6c652e6c6f67;

    function _send(bytes memory payload) private view {
        address c = CONSOLE_ADDRESS;
        assembly {
            pop(staticcall(gas(), c, add(payload, 32), mload(payload), 0, 0))
        }
    }
    function log(string memory a) internal view {
        _send(abi.encodeWithSignature("log(string)", a));
    }
    function log(string memory a, address b) internal view {
        _send(abi.encodeWithSignature("log(string,address)", a, b));
    }
    function log(string memory a, uint256 b) internal view {
        _send(abi.encodeWithSignature("log(string,uint256)", a, b));
    }
}
