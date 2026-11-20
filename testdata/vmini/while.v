// A V `for i in lo .. hi` range loop lowered to a while loop.
fn main() {
    mut sum := 0
    for i in 0 .. 5 {
        sum = sum + i
    }
    exit(sum)
}
