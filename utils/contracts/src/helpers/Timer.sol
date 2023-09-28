//SPDX-License-Identifier: MIT
// todo: do we need reya license?

pragma solidity >=0.8.19;

library Timer {
    using Timer for Timer.Data;

    /**
     * @notice Thrown when a timer is scheduled with a past start timestamp
     * @param id The timer id
     * @param startTimestamp The start timestamp of the timer
     * @param blockTimestamp The current block's timestamp 
     */
    error ExpiredTimerSchedule(bytes32 id, uint256 startTimestamp, uint256 blockTimestamp);

    /**
     * @notice Thrown when an active timer is (re-)scheduled
     * @param id The timer id
     * @param blockTimestamp The current block's timestamp
     */
    error CannotScheduleActiveTimer(bytes32 id, uint256 blockTimestamp);

    /**
     * @dev Structure for tracking timers
     */
    struct Data {
        bytes32 id;
        uint256 startTimestamp;
        uint256 endTimestamp;
    }

    /**
     * @notice Returns the timer stored at the specified timer id
     * @param id The timer id
     */
    function load(bytes32 id) private pure returns (Data storage timer) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Timer", id));
        assembly {
            timer.slot := s
        }
    }

    /**
     * @notice Creates timer if inexistent and returns the timer stored at the
     * specified timer id
     * @param id The timer id
     */
    function loadOrCreate(bytes32 id) internal returns (Data storage timer) {
        timer = load(id);
        if (timer.id == 0) {
            timer.id = id;
        }
    }

    /**
     * @notice Returns whether a given timer is active or not.
     */
    function isActive(Data storage self) internal view returns (bool) {
        return (self.startTimestamp <= block.timestamp && block.timestamp < self.endTimestamp);
    }

    /**
     * @notice Schedules a given timer
     * @param startTimestamp The start timestamp of the timer
     * @param durationInSeconds The duration of the timer, in seconds
     */
    function schedule(Data storage self, uint256 startTimestamp, uint256 durationInSeconds) internal {
        if (startTimestamp < block.timestamp) {
            revert ExpiredTimerSchedule(self.id, startTimestamp, block.timestamp);
        }

        if (self.isActive()) {
            revert CannotScheduleActiveTimer(self.id, block.timestamp);
        }

        self.startTimestamp = startTimestamp;
        self.endTimestamp = self.startTimestamp + durationInSeconds;
    }

    /**
     * @notice Start a given timer (ie schedules a timer that starts now)
     * @param durationInSeconds The duration of the timer, in seconds
     */
    function start(Data storage self, uint256 durationInSeconds) internal {
        self.schedule(block.timestamp, durationInSeconds);
    }
}