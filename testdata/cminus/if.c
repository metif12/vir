/* Both arms of a conditional, with a nested else-if chain. */
int main() {
    int x = 3;
    if (x > 9) {
        return 100;
    } else {
        if (x == 3) {
            return 7;
        }
        return 8;
    }
}
