<?php

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "CLI only.\n");
    exit(2);
}

$documentRoot = rtrim($argv[1] ?? '', '/');

if ($documentRoot === '' || !is_dir($documentRoot)) {
    fwrite(STDERR, "Usage: configure-local-bitrix.php /absolute/document/root\n");
    exit(2);
}

$requiredEnvironment = [
    'LOCAL_DB_NAME',
    'LOCAL_DB_USER',
    'LOCAL_DB_PASSWORD',
    'LOCAL_REDIS_PASSWORD',
];

$environment = [];
foreach ($requiredEnvironment as $name) {
    $value = getenv($name);
    if ($value === false || $value === '') {
        fwrite(STDERR, "Missing environment variable: {$name}\n");
        exit(2);
    }
    $environment[$name] = $value;
}

function writePhpArray(string $path, array $value): void
{
    $directory = dirname($path);
    $temporary = tempnam($directory, '.local-settings-');
    if ($temporary === false) {
        throw new RuntimeException("Cannot create a temporary file in {$directory}");
    }

    $contents = "<?php\n\nreturn " . var_export($value, true) . ";\n";

    try {
        if (file_put_contents($temporary, $contents, LOCK_EX) === false) {
            throw new RuntimeException("Cannot write {$temporary}");
        }
        chmod($temporary, 0660);
        if (!rename($temporary, $path)) {
            throw new RuntimeException("Cannot replace {$path}");
        }
    } finally {
        if (is_file($temporary)) {
            unlink($temporary);
        }
    }
}

function configureSettings(array &$settings, array $environment): void
{
    if (!isset($settings['connections']['value']['default'])) {
        throw new RuntimeException('Default Bitrix database connection is missing.');
    }

    $connection =& $settings['connections']['value']['default'];
    $connection['host'] = 'mysql';
    $connection['database'] = $environment['LOCAL_DB_NAME'];
    $connection['login'] = $environment['LOCAL_DB_USER'];
    $connection['password'] = $environment['LOCAL_DB_PASSWORD'];

    if (isset($settings['cache']['value']['redis']) && is_array($settings['cache']['value']['redis'])) {
        $redis =& $settings['cache']['value']['redis'];
        $redis['host'] = 'redis';
        $redis['port'] = 6379;
        $redis['password'] = $environment['LOCAL_REDIS_PASSWORD'];
    }
}

$settingsPath = $documentRoot . '/bitrix/.settings.php';
if (!is_file($settingsPath)) {
    throw new RuntimeException("Bitrix settings file is missing: {$settingsPath}");
}

$settings = require $settingsPath;
if (!is_array($settings)) {
    throw new RuntimeException("Bitrix settings file did not return an array: {$settingsPath}");
}

configureSettings($settings, $environment);
writePhpArray($settingsPath, $settings);

$extraSettingsPath = $documentRoot . '/bitrix/.settings_extra.php';
if (is_file($extraSettingsPath)) {
    $extraSettings = require $extraSettingsPath;
    if (is_array($extraSettings) && isset($extraSettings['connections']['value']['default'])) {
        configureSettings($extraSettings, $environment);
        writePhpArray($extraSettingsPath, $extraSettings);
    }
}

$dbconnPath = $documentRoot . '/bitrix/php_interface/dbconn.php';
if (is_file($dbconnPath)) {
    $dbconn = file_get_contents($dbconnPath);
    if ($dbconn === false) {
        throw new RuntimeException("Cannot read {$dbconnPath}");
    }

    $replacements = [
        '/^\s*\$DBHost\s*=.*?;\s*$/m' => '$DBHost = \'mysql\';',
        '/^\s*\$DBName\s*=.*?;\s*$/m' => '$DBName = ' . var_export($environment['LOCAL_DB_NAME'], true) . ';',
        '/^\s*\$DBLogin\s*=.*?;\s*$/m' => '$DBLogin = ' . var_export($environment['LOCAL_DB_USER'], true) . ';',
        '/^\s*\$DBPassword\s*=.*?;\s*$/m' => '$DBPassword = ' . var_export($environment['LOCAL_DB_PASSWORD'], true) . ';',
    ];

    $updated = $dbconn;
    foreach ($replacements as $pattern => $replacement) {
        $next = preg_replace_callback(
            $pattern,
            static fn(array $_match): string => $replacement,
            $updated
        );
        if ($next === null) {
            throw new RuntimeException("Cannot parse {$dbconnPath}");
        }
        $updated = $next;
    }

    if (file_put_contents($dbconnPath, $updated, LOCK_EX) === false) {
        throw new RuntimeException("Cannot update {$dbconnPath}");
    }
}

foreach (['after_connect.php', 'after_connect_d7.php'] as $fileName) {
    $path = $documentRoot . '/bitrix/php_interface/' . $fileName;
    if (!is_file($path)) {
        continue;
    }

    $contents = file_get_contents($path);
    if ($contents === false) {
        throw new RuntimeException("Cannot read {$path}");
    }

    $lines = preg_split('/(?<=\n)/', $contents) ?: [];
    $lines = array_filter(
        $lines,
        static fn(string $line): bool => stripos($line, 'innodb_strict_mode') === false
    );

    if (file_put_contents($path, implode('', $lines), LOCK_EX) === false) {
        throw new RuntimeException("Cannot update {$path}");
    }
}

echo "Local Bitrix database and Redis settings updated.\n";
