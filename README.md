# minimuxer

minimuxer is the lockdown muxer used by [SideStore](https://github.com/SideStore/SideStore). It runs on device through [em_proxy](https://github.com/SideStore/em_proxy).

## Development

While minimuxer is built to run on device, it is recommended to test from your computer through USB to speed up the development process. (Obviously, you should still test on device; don't forget to
change SideStore to call your function.)

SideStore communicates with minimuxer through C bindings called by Swift. If you are unsure on how to pass arguments to functions this way, check the currently implemented functions for examples.

To test off device, open [tests.rs](src/tests.rs) and add a new test function running whatever you are working on (make sure it calls `init()`). You can then use
`cargo test <test function name> -- --nocapture` to run it. (`-- --nocapture` allows for logs to be shown, which are essential for debugging and knowing if a test did what it was supposed to do)

After implementing your feature, you should also run `cargo clippy --no-deps` to lint your code.

Note: tests currently don't automatically mount the developer disk image, you must do that yourself with `ideviceimagemounter` or open SideStore on device and let the auto mounter mount it (check
minimuxer logs in View Error Logs to see if it did so successfully).
