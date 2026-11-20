// Nested conditionals with early exits.
fn main() {
    mut x := 3
    if x > 9 {
        exit(100)
    } else {
        if x == 3 {
            exit(7)
        }
        exit(8)
    }
}
