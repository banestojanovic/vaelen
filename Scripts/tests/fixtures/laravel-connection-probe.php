<?php

declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;

ini_set('display_errors', '0');
ini_set('log_errors', '0');
error_reporting(0);

$phase = $argv[1] ?? '';
$expectationPath = $argv[2] ?? '';
$fail = static function (string $reason): never {
    fwrite(STDERR, 'Laravel acceptance failed: ' . $reason . PHP_EOL);
    exit(1);
};

if (!in_array($phase, ['uncached', 'cached'], true) || $expectationPath === '' || $argc !== 3) {
    $fail('invalid invocation');
}

if (PHP_VERSION !== '8.4.27') {
    $fail('php version');
}

$expectationBytes = @file_get_contents($expectationPath);
$expected = is_string($expectationBytes) ? json_decode($expectationBytes, true) : null;
$paths = [
    'database.default',
    'database.connections.mysql.host',
    'database.connections.mysql.port',
    'database.connections.mysql.database',
    'database.connections.mysql.username',
    'database.connections.mysql.password',
];
$expectedPaths = is_array($expected) ? array_keys($expected) : [];
sort($expectedPaths);
$requiredPaths = $paths;
sort($requiredPaths);
if (!is_array($expected) || $expectedPaths !== $requiredPaths || count($expected) !== count($paths)) {
    $fail('expectation shape');
}

try {
    require getcwd() . '/vendor/autoload.php';
    if (Composer\InstalledVersions::getPrettyVersion('laravel/framework') !== 'v13.39.0') {
        $fail('laravel version');
    }
    if (Composer\InstalledVersions::getPrettyVersion('vlucas/phpdotenv') !== 'v5.8.0') {
        $fail('phpdotenv version');
    }

    $app = require getcwd() . '/bootstrap/app.php';
    $app->make(Kernel::class)->bootstrap();

    if ($app->configurationIsCached() !== ($phase === 'cached')) {
        $fail('phase=' . $phase . ' config cache');
    }
    if ($phase === 'uncached' && ($_ENV['CUSTOM_VALUE'] ?? null) !== 'keep') {
        $fail('phase=uncached dotenv marker');
    }
    if ($phase === 'cached' && array_key_exists('CUSTOM_VALUE', $_ENV)) {
        $fail('phase=cached dotenv marker');
    }

    foreach ($paths as $path) {
        if ($app['config']->get($path) !== $expected[$path]) {
            $fail('phase=' . $phase . ' field=' . $path);
        }
    }

    $result = $app['db']->connection()->selectOne('SELECT 1 AS accepted');
    if ((string) ($result->accepted ?? '') !== '1') {
        $fail('phase=' . $phase . ' query');
    }
} catch (Throwable) {
    $fail('phase=' . $phase . ' bootstrap');
}

echo 'LARAVEL_CONNECTION ' . $phase . ' PASS' . PHP_EOL;
