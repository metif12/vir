// Mutable locals, reassignment, division and remainder.
fn main() {
    mut a := 40
    mut b := 6
    a = a / b
    b = a % 4
    exit(a + b)
}
