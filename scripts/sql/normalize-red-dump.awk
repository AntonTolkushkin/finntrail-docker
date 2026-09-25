# Convert only CREATE TABLE definitions. INSERT data is intentionally untouched.
/^CREATE TABLE / {
    in_create_table = 1
}

{
    if (in_create_table) {
        gsub(/utf8mb3_unicode_ci/, "utf8mb4_unicode_ci")
        gsub(/utf8mb3_general_ci/, "utf8mb4_unicode_ci")
        gsub(/utf8mb3_bin/, "utf8mb4_bin")
        gsub(/utf8_unicode_ci/, "utf8mb4_unicode_ci")
        gsub(/utf8_general_ci/, "utf8mb4_unicode_ci")
        gsub(/utf8_bin/, "utf8mb4_bin")
        gsub(/utf8mb3/, "utf8mb4")
        gsub(/DEFAULT CHARSET=utf8 /, "DEFAULT CHARSET=utf8mb4 ")
        gsub(/DEFAULT CHARSET=utf8;/, "DEFAULT CHARSET=utf8mb4;")
        gsub(/CHARACTER SET utf8 /, "CHARACTER SET utf8mb4 ")
    }

    print
}

in_create_table && /;[[:space:]]*$/ {
    in_create_table = 0
}
