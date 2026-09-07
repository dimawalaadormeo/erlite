<?php

$baseUrl = 'https://erlite.example:8443';
$token = 'replace-with-service-token';
$databaseId = rawurlencode('merchant-100');
$payload = json_encode([
    'transaction_id' => bin2hex(random_bytes(16)),
    'statements' => [[
        'sql' => 'INSERT INTO products(sku,name) VALUES(?,?)',
        'params' => ['A1', 'Widget'],
    ]],
], JSON_THROW_ON_ERROR);

$curl = curl_init("$baseUrl/v1/databases/$databaseId/transactions");
curl_setopt_array($curl, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $payload,
    CURLOPT_HTTPHEADER => [
        "Authorization: Bearer $token",
        'Content-Type: application/json',
    ],
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 20,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
]);

$response = curl_exec($curl);
if ($response === false) {
    throw new RuntimeException(curl_error($curl));
}
echo $response, PHP_EOL;
