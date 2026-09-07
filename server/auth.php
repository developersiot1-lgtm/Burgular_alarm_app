<?php
// ================================================================
// auth.php — https://monsow.in/alarm/auth.php
// FIXED: all switch cases have break, output buffering catches
//        any stray PHP warnings before JSON is sent
// ================================================================

// ── Catch ANY stray output (PHP warnings, notices) before JSON ──
ob_start();

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    ob_end_clean();
    http_response_code(200);
    exit();
}

// ── Suppress display, log only ───────────────────────────────────
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);

// ================================================================
// SMTP CREDENTIALS
// ================================================================
define('SMTP_HOST',     'smtp.gmail.com');
define('SMTP_PORT',     587);
define('SMTP_USER',     'aarthiravi63@gmail.com');
define('SMTP_PASS',     'fkgq nsrk sqvs zclx');
define('SMTP_FROM',     'aarthiravi63@gmail.com');
define('SMTP_FROM_NAME','Alarm App');

// ================================================================
// LOAD PHPMailer — tries every possible path/structure
// ================================================================
$phpmailerLoaded = false;

// Path 1: Composer vendor autoload
if (!$phpmailerLoaded && file_exists(__DIR__ . '/vendor/autoload.php')) {
    require_once __DIR__ . '/vendor/autoload.php';
    $phpmailerLoaded = class_exists('PHPMailer\\PHPMailer\\PHPMailer');
}

// Path 2: Manual install — /PHPMailer/src/
if (!$phpmailerLoaded && file_exists(__DIR__ . '/PHPMailer/src/PHPMailer.php')) {
    require_once __DIR__ . '/PHPMailer/src/Exception.php';
    require_once __DIR__ . '/PHPMailer/src/PHPMailer.php';
    require_once __DIR__ . '/PHPMailer/src/SMTP.php';
    $phpmailerLoaded = class_exists('PHPMailer\\PHPMailer\\PHPMailer');
}

// Path 3: Zip extracted as PHPMailer-master/src/
if (!$phpmailerLoaded && file_exists(__DIR__ . '/PHPMailer-master/src/PHPMailer.php')) {
    require_once __DIR__ . '/PHPMailer-master/src/Exception.php';
    require_once __DIR__ . '/PHPMailer-master/src/PHPMailer.php';
    require_once __DIR__ . '/PHPMailer-master/src/SMTP.php';
    $phpmailerLoaded = class_exists('PHPMailer\\PHPMailer\\PHPMailer');
}

// Path 4: Files placed directly in /PHPMailer/ (no src subfolder)
if (!$phpmailerLoaded && file_exists(__DIR__ . '/PHPMailer/PHPMailer.php')) {
    require_once __DIR__ . '/PHPMailer/Exception.php';
    require_once __DIR__ . '/PHPMailer/PHPMailer.php';
    require_once __DIR__ . '/PHPMailer/SMTP.php';
    $phpmailerLoaded = class_exists('PHPMailer\\PHPMailer\\PHPMailer');
}

error_log('PHPMailer loaded: ' . ($phpmailerLoaded ? 'YES' : 'NO'));

// ================================================================
// HELPERS
// ================================================================
function getDB(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO(
            'mysql:host=localhost;dbname=mons_alarm_db;charset=utf8mb4',
            'mons_alarm_user',
            'Vpm26@1983',
            [PDO::ATTR_ERRMODE      => PDO::ERRMODE_EXCEPTION,
             PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
        );
    }
    return $pdo;
}

function sendJSON(array $data, int $code = 200): void {
    // Discard any stray PHP output (warnings/notices) before sending JSON
    ob_end_clean();
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);
    exit();
}

function getRelatedDeviceUuids(PDO $db, string $deviceUuid): array {
    $deviceUuid = trim($deviceUuid);
    if ($deviceUuid === '') return [];

    $uuids = expandMacAliases([$deviceUuid]);
    $stmt = $db->prepare(
        "SELECT device_uuid, ble_service_uuid, mac_address
           FROM device_registry
          WHERE (device_uuid IN (" . placeholdersFor($uuids) . ")
                 OR ble_service_uuid IN (" . placeholdersFor($uuids) . ")
                 OR mac_address IN (" . placeholdersFor($uuids) . "))
            AND is_active = 1
          LIMIT 5"
    );
    $stmt->execute(array_merge($uuids, $uuids, $uuids));
    $hubs = $stmt->fetchAll();

    foreach ($hubs as $hub) {
        if (!empty($hub['device_uuid'])) $uuids[] = $hub['device_uuid'];
        if (!empty($hub['ble_service_uuid'])) $uuids[] = $hub['ble_service_uuid'];
        if (!empty($hub['mac_address'])) $uuids[] = $hub['mac_address'];
    }

    return expandMacAliases($uuids);
}

function macAliasVariants(string $value): array {
    $hex = strtoupper(preg_replace('/[^0-9A-F]/', '', $value));
    if (strlen($hex) !== 12) return [];

    $bytes = str_split($hex, 2);
    $last = hexdec($bytes[5]);
    $aliases = [];
    foreach ([0, 2, -2, 1, -1] as $delta) {
        $copy = $bytes;
        $copy[5] = sprintf('%02X', ($last + $delta) & 0xFF);
        $aliases[] = implode(':', $copy);
    }
    return array_values(array_unique($aliases));
}

function expandMacAliases(array $values): array {
    $out = [];
    foreach ($values as $value) {
        $value = trim((string)$value);
        if ($value !== '' && !in_array($value, $out, true)) {
            $out[] = $value;
        }
        foreach (macAliasVariants($value) as $alias) {
            if ($alias !== '' && !in_array($alias, $out, true)) {
                $out[] = $alias;
            }
        }
    }
    return $out;
}

function placeholdersFor(array $items): string {
    return implode(',', array_fill(0, count($items), '?'));
}

function getInput(): array {
    $raw = file_get_contents('php://input');
    if (empty($raw)) return [];
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function sendOtpEmail(string $toEmail, string $toName, string $otp): bool {
    global $phpmailerLoaded;

    $subject  = 'Alarm App — Password Reset Code';
    $bodyHtml = '<div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;'
              . 'border:1px solid #e0e0e0;border-radius:10px;overflow:hidden;">'
              . '<div style="background:#1565C0;padding:24px;text-align:center;">'
              . '<h2 style="color:#fff;margin:0;">Alarm Control</h2>'
              . '<p style="color:#90CAF9;margin:4px 0 0;">Password Reset</p>'
              . '</div><div style="padding:28px;">'
              . '<p style="color:#333;">Hi <strong>' . htmlspecialchars($toName) . '</strong>,</p>'
              . '<p style="color:#555;">Your password reset code is:</p>'
              . '<div style="text-align:center;margin:24px 0;">'
              . '<span style="font-size:40px;font-weight:bold;letter-spacing:10px;'
              . 'color:#1565C0;background:#E3F2FD;padding:14px 28px;border-radius:10px;">'
              . $otp . '</span></div>'
              . '<p style="color:#888;text-align:center;">Expires in 15 minutes.</p>'
              . '</div></div>';

    $bodyText = "Hi $toName,\n\nYour password reset code is: $otp\n\nExpires in 15 minutes.\n\n— Alarm Control App";

    if ($phpmailerLoaded && class_exists('PHPMailer\\PHPMailer\\PHPMailer')) {
        try {
            // Use fully qualified class name — works with any install method
            $mailerClass = 'PHPMailer\\PHPMailer\\PHPMailer';
            $mail = new $mailerClass(true);
            $mail->isSMTP();
            $mail->Host       = SMTP_HOST;
            $mail->SMTPAuth   = true;
            $mail->Username   = SMTP_USER;
            $mail->Password   = SMTP_PASS;
            $mail->SMTPSecure = 'tls';   // 'tls' = STARTTLS on port 587
            $mail->Port       = SMTP_PORT;
            $mail->CharSet    = 'UTF-8';
            $mail->setFrom(SMTP_FROM, SMTP_FROM_NAME);
            $mail->addAddress($toEmail, $toName);
            $mail->Subject = $subject;
            $mail->isHTML(true);
            $mail->Body    = $bodyHtml;
            $mail->AltBody = $bodyText;
            $mail->send();
            error_log("✅ OTP sent via PHPMailer to $toEmail OTP=$otp");
            return true;
        } catch (\Exception $e) {
            error_log("❌ PHPMailer send error: " . $e->getMessage());
            // fall through to mail() fallback below
        }
    } else {
        error_log("❌ PHPMailer class not found even after loading files");
    }

    // Fallback
    $headers  = "From: " . SMTP_FROM_NAME . " <" . SMTP_FROM . ">\r\n";
    $headers .= "MIME-Version: 1.0\r\nContent-Type: text/html; charset=UTF-8\r\n";
    $sent = @mail($toEmail, $subject, $bodyHtml, $headers);
    error_log($sent ? "OTP sent via mail() to $toEmail" : "mail() failed for $toEmail OTP=$otp");
    return $sent;
}

// ================================================================
// ROUTER
// ================================================================
$action = $_GET['action'] ?? '';

try {
    switch ($action) {

        // ── REGISTER ─────────────────────────────────────────────
        case 'register': {
            $data  = getInput();
            $name  = trim($data['name']     ?? '');
            $email = trim($data['email']    ?? '');
            $pass  = trim($data['password'] ?? '');

            if (!$name || !$email || !$pass)
                sendJSON(['success' => false, 'message' => 'Name, email and password required'], 400);

            if (!filter_var($email, FILTER_VALIDATE_EMAIL))
                sendJSON(['success' => false, 'message' => 'Invalid email address'], 400);

            if (strlen($pass) < 6)
                sendJSON(['success' => false, 'message' => 'Password must be at least 6 characters'], 400);

            $db    = getDB();
            $check = $db->prepare("SELECT id FROM app_users WHERE email = ?");
            $check->execute([$email]);
            if ($check->fetch())
                sendJSON(['success' => false, 'message' => 'Email already registered'], 409);

            $hash = password_hash($pass, PASSWORD_BCRYPT);
            $stmt = $db->prepare("INSERT INTO app_users (name, email, password_hash) VALUES (?, ?, ?)");
            $stmt->execute([$name, $email, $hash]);
            $userId = (int)$db->lastInsertId();

            sendJSON(['success' => true, 'message' => 'Account created',
                      'user_id' => $userId, 'name' => $name, 'email' => $email]);
            break;
        }
        // ── SHARE DEVICE WITH ANOTHER USER (by email) ────────────
        case 'share_device': {
            $data       = getInput();
            $ownerId    = (int)($data['owner_id'] ?? 0);
            $email      = trim($data['email'] ?? '');
            $deviceUuid = trim($data['device_uuid'] ?? '');
            $role       = strtolower(trim($data['role'] ?? 'user'));
            $role       = ($role === 'admin') ? 'admin' : 'user';

            if (!$ownerId || !$email || !$deviceUuid) {
                sendJSON(['success' => false, 'message' => 'owner_id, email and device_uuid required'], 400);
            }

            if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
                sendJSON(['success' => false, 'message' => 'Invalid email address'], 400);
            }

            $db = getDB();

            $stmt = $db->prepare("SELECT id, name FROM app_users WHERE id = ? AND is_active = 1");
            $stmt->execute([$ownerId]);
            $owner = $stmt->fetch();
            if (!$owner) {
                sendJSON(['success' => false, 'message' => 'Owner not found'], 400);
            }

            $relatedUuids = getRelatedDeviceUuids($db, $deviceUuid);
            if (empty($relatedUuids)) {
                sendJSON(['success' => false, 'message' => 'Device not found'], 404);
            }
            $canonicalDeviceUuid = $relatedUuids[0];
            $placeholders = placeholdersFor($relatedUuids);

            // Only users who are admins/owners for this physical device can share it.
            $params = array_merge([$ownerId], $relatedUuids);
            $stmt = $db->prepare("
                SELECT id
                  FROM user_devices
                 WHERE user_id = ?
                   AND device_uuid IN ($placeholders)
                   AND (role = 'admin' OR shared_by IS NULL)
                 LIMIT 1
            ");
            $stmt->execute($params);
            if (!$stmt->fetch()) {
                sendJSON(['success' => false, 'message' => 'Only admins can share this device'], 403);
            }

            $stmt = $db->prepare("SELECT id FROM app_users WHERE email = ?");
            $stmt->execute([$email]);
            $existingUser = $stmt->fetch();

            if ($existingUser) {
                $targetId = (int)$existingUser['id'];

                if ($targetId === $ownerId) {
                    sendJSON(['success' => false, 'message' => 'You cannot share a device with yourself'], 400);
                }

                $db->prepare("
                    INSERT INTO user_devices (user_id, device_uuid, shared_by, role)
                    VALUES (?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE
                        shared_by = VALUES(shared_by),
                        role = VALUES(role)
                ")->execute([$targetId, $canonicalDeviceUuid, $ownerId, $role]);

                sendJSON([
                    'success' => true,
                    'message' => 'Device shared with existing user',
                    'user_id' => $targetId,
                    'role' => $role
                ]);
            } else {
                $tempPassword = bin2hex(random_bytes(4));
                $tempName = explode('@', $email)[0];
                $hash = password_hash($tempPassword, PASSWORD_BCRYPT);

                $stmt = $db->prepare("
                    INSERT INTO app_users (name, email, password_hash, is_active, created_at)
                    VALUES (?, ?, ?, 1, NOW())
                ");
                $stmt->execute([$tempName, $email, $hash]);
                $targetId = (int)$db->lastInsertId();

                $db->prepare("INSERT INTO user_devices (user_id, device_uuid, shared_by, role) VALUES (?, ?, ?, ?)")
                   ->execute([$targetId, $canonicalDeviceUuid, $ownerId, $role]);

                $db->prepare("
                    INSERT INTO activity_logs (timestamp, event, device, user, details)
                    VALUES (NOW(), 'New User Auto-Registered via Share', ?, ?, ?)
                ")->execute(['Control Panel', $owner['name'], "Email: $email, Role: $role"]);

                sendJSON([
                    'success' => true,
                    'message' => 'New user auto-created and device shared',
                    'user_id' => $targetId,
                    'temp_password' => $tempPassword,
                    'login_info' => "$email / $tempPassword",
                    'role' => $role
                ]);
            }
            break;
        }
        // ── LOGIN ─────────────────────────────────────────────────
        case 'login': {
            $data  = getInput();
            $email = trim($data['email']    ?? '');
            $pass  = trim($data['password'] ?? '');

            if (!$email || !$pass)
                sendJSON(['success' => false, 'message' => 'Email and password required'], 400);

            $db   = getDB();
            $stmt = $db->prepare(
                "SELECT id, name, email, password_hash, is_active FROM app_users WHERE email = ?"
            );
            $stmt->execute([$email]);
            $user = $stmt->fetch();

            if (!$user || !password_verify($pass, $user['password_hash']))
                sendJSON(['success' => false, 'message' => 'Invalid email or password'], 401);

            if (!(int)$user['is_active'])
                sendJSON(['success' => false, 'message' => 'Account is disabled'], 403);

            $db->prepare("UPDATE app_users SET last_login_at = NOW() WHERE id = ?")
               ->execute([$user['id']]);

            sendJSON(['success' => true, 'message' => 'Login successful',
                      'user_id' => (int)$user['id'],
                      'name'    => $user['name'],
                      'email'   => $user['email']]);
            break;
        }

        // ── FORGOT PASSWORD ───────────────────────────────────────
        case 'forgot_password': {
            $data  = getInput();
            $email = trim($data['email'] ?? '');

            if (!$email)
                sendJSON(['success' => false, 'message' => 'Email is required'], 400);

            if (!filter_var($email, FILTER_VALIDATE_EMAIL))
                sendJSON(['success' => false, 'message' => 'Invalid email address'], 400);

            $db   = getDB();
            $stmt = $db->prepare("SELECT id, name FROM app_users WHERE email = ? AND is_active = 1");
            $stmt->execute([$email]);
            $user = $stmt->fetch();

            // Always success — prevents email enumeration
            if (!$user)
                sendJSON(['success' => true, 'message' => 'If that email is registered, a reset code has been sent']);

            $otp = str_pad((string)random_int(100000, 999999), 6, '0', STR_PAD_LEFT);

            // ✅ Use MySQL NOW() + INTERVAL to avoid PHP/MySQL timezone mismatch
            // This guarantees expiry is set in the same timezone as the NOW() check
            $db->prepare(
                "UPDATE app_users
                    SET reset_token = ?,
                        reset_token_expiry = DATE_ADD(NOW(), INTERVAL 15 MINUTE)
                  WHERE id = ?"
            )->execute([$otp, $user['id']]);

            // ✅ Log the OTP and expiry for debugging
            $check = $db->prepare("SELECT reset_token, reset_token_expiry, NOW() as db_now FROM app_users WHERE id = ?");
            $check->execute([$user['id']]);
            $dbrow = $check->fetch();
            error_log("OTP saved: token={$dbrow['reset_token']} expiry={$dbrow['reset_token_expiry']} db_now={$dbrow['db_now']}");

            $sent = sendOtpEmail($email, $user['name'], $otp);

            if ($sent) {
                sendJSON(['success' => true, 'message' => 'Reset code sent to ' . $email]);
            } else {
                sendJSON(['success' => false,
                    'message' => 'Email could not be sent. PHPMailer not installed or SMTP wrong.'], 500);
            }
            break;
        }

        // ── VERIFY OTP ────────────────────────────────────────────
        case 'verify_otp': {
            $data  = getInput();
            $email = trim($data['email'] ?? '');
            $otp   = trim(str_replace(' ', '', $data['otp'] ?? '')); // strip spaces

            if (!$email || !$otp)
                sendJSON(['success' => false, 'message' => 'Email and OTP required'], 400);

            $db = getDB();

            // Step 1: Find the user and their current token (ignore expiry first)
            $row = $db->prepare(
                "SELECT id, reset_token, reset_token_expiry, NOW() as db_now
                   FROM app_users WHERE email = ? AND is_active = 1"
            );
            $row->execute([$email]);
            $user = $row->fetch();

            // Debug log — visible in server error_log
            error_log("verify_otp: email=$email otp_entered=$otp"
                . " db_token=" . ($user['reset_token'] ?? 'NULL')
                . " expiry="   . ($user['reset_token_expiry'] ?? 'NULL')
                . " db_now="   . ($user['db_now'] ?? 'NULL'));

            if (!$user) {
                sendJSON(['success' => false, 'message' => 'Email not found'], 400);
            }

            if ($user['reset_token'] === null) {
                sendJSON(['success' => false, 'message' => 'No reset code was requested. Please request a new code.'], 400);
            }

            // Check token match (case-insensitive, both trimmed)
            if (trim($user['reset_token']) !== trim($otp)) {
                sendJSON(['success' => false,
                    'message' => 'Wrong code. Check your email for the latest code.'], 400);
            }

            // Check expiry separately so we can give a clear message
            if ($user['reset_token_expiry'] < $user['db_now']) {
                sendJSON(['success' => false,
                    'message' => 'Code has expired. Please request a new one.'], 400);
            }

            sendJSON(['success' => true, 'message' => 'Code verified']);
            break;
        }

        // ── RESET PASSWORD ────────────────────────────────────────
        case 'reset_password': {
            $data    = getInput();
            $email   = trim($data['email']        ?? '');
            $otp     = trim($data['otp']          ?? '');
            $newPass = trim($data['new_password'] ?? '');

            if (!$email || !$otp || !$newPass)
                sendJSON(['success' => false, 'message' => 'Email, OTP and new password required'], 400);

            if (strlen($newPass) < 6)
                sendJSON(['success' => false, 'message' => 'Password must be at least 6 characters'], 400);

            $db  = getDB();
            $otp = trim(str_replace(' ', '', $otp)); // strip spaces

            $row = $db->prepare(
                "SELECT id, reset_token, reset_token_expiry, NOW() as db_now
                   FROM app_users WHERE email = ? AND is_active = 1"
            );
            $row->execute([$email]);
            $user = $row->fetch();

            if (!$user || $user['reset_token'] === null)
                sendJSON(['success' => false, 'message' => 'No reset code found. Request a new one.'], 400);

            if (trim($user['reset_token']) !== trim($otp))
                sendJSON(['success' => false, 'message' => 'Wrong code. Check your email.'], 400);

            if ($user['reset_token_expiry'] < $user['db_now'])
                sendJSON(['success' => false, 'message' => 'Code expired. Request a new one.'], 400);

            $hash = password_hash($newPass, PASSWORD_BCRYPT);
            $db->prepare(
                "UPDATE app_users
                    SET password_hash = ?, reset_token = NULL, reset_token_expiry = NULL
                  WHERE id = ?"
            )->execute([$hash, $user['id']]);

            sendJSON(['success' => true, 'message' => 'Password reset successfully']);
            break;
        }

        // ── ADD USER DEVICE ───────────────────────────────────────
        case 'add_user_device': {
            $data       = getInput();
            $userId     = (int)($data['user_id'] ?? 0);
            $deviceUuid = trim($data['device_uuid'] ?? '');
            $role       = strtolower(trim($data['role'] ?? 'admin'));
            $role       = ($role === 'user') ? 'user' : 'admin';

            if (!$userId || !$deviceUuid) {
                sendJSON(['success' => false, 'message' => 'user_id and device_uuid required'], 400);
            }

            $db = getDB();
            $relatedUuids = getRelatedDeviceUuids($db, $deviceUuid);
            if (empty($relatedUuids)) {
                sendJSON(['success' => false, 'message' => 'Device not found in registry'], 404);
            }

            $canonicalDeviceUuid = $relatedUuids[0];

            // A newly scanned device becomes the main admin's device.
            // If this row was shared by someone else, do not accidentally upgrade it.
            $db->prepare("
                INSERT INTO user_devices (user_id, device_uuid, shared_by, role)
                VALUES (?, ?, NULL, ?)
                ON DUPLICATE KEY UPDATE
                    role = CASE WHEN shared_by IS NULL THEN VALUES(role) ELSE role END
            ")->execute([$userId, $canonicalDeviceUuid, $role]);

            sendJSON([
                'success' => true,
                'message' => 'Device linked to account',
                'role' => $role,
                'device_uuid' => $canonicalDeviceUuid,
                'aliases' => $relatedUuids
            ]);
            break;
        }

        // ── GET USER DEVICES ──────────────────────────────────────
        case 'get_user_devices': {
            $userId = (int)($_GET['user_id'] ?? 0);

            if (!$userId) {
                sendJSON(['success' => false, 'message' => 'user_id required'], 400);
            }

            $db   = getDB();
            $stmt = $db->prepare(
                "SELECT dr.device_uuid, dr.device_name, dr.device_type,
                        dr.status, dr.battery_level, dr.signal_strength,
                        dr.last_seen_at, dr.registered_at, ud.added_at,
                        CASE WHEN ud.shared_by IS NULL THEN 'admin' ELSE COALESCE(ud.role, 'user') END AS role,
                        CASE WHEN ud.shared_by IS NULL THEN 'owner' ELSE 'shared' END AS access_type,
                        ud.shared_by
                   FROM user_devices ud
                   JOIN device_registry dr
                     ON (dr.device_uuid = ud.device_uuid
                         OR dr.ble_service_uuid = ud.device_uuid
                         OR dr.mac_address = ud.device_uuid)
                  WHERE ud.user_id = ? AND dr.is_active = 1
                  ORDER BY ud.added_at DESC"
            );
            $stmt->execute([$userId]);
            $devices = $stmt->fetchAll();

            sendJSON(['success' => true, 'total' => count($devices), 'devices' => $devices]);
            break;
        }
        // ── REMOVE USER DEVICE ────────────────────────────────────
        case 'remove_user_device': {
            $data       = getInput();
            $userId     = (int)($data['user_id']    ?? 0);
            $deviceUuid = trim($data['device_uuid'] ?? '');

            if (!$userId || !$deviceUuid)
                sendJSON(['success' => false, 'message' => 'user_id and device_uuid required'], 400);

            $db = getDB();
            $relatedUuids = getRelatedDeviceUuids($db, $deviceUuid);
            if (empty($relatedUuids)) $relatedUuids = [$deviceUuid];
            $placeholders = placeholdersFor($relatedUuids);
            $params = array_merge([$userId], $relatedUuids);
            $db->prepare("DELETE FROM user_devices WHERE user_id = ? AND device_uuid IN ($placeholders)")
               ->execute($params);

            sendJSON(['success' => true, 'message' => 'Device removed from account']);
            break;
        }

        // ── STATUS CHECK (open in browser to verify) ──────────────
        default: {
            // Show exactly which files exist — helps debug PHPMailer path
            $dir = __DIR__;
            sendJSON([
                'message'      => 'Alarm Auth API v2',
                'status'       => 'OK',
                'phpmailer'    => $phpmailerLoaded ? 'loaded' : 'NOT loaded',
                'smtp_host'    => SMTP_HOST,
                'smtp_user'    => SMTP_USER,
                'server_dir'   => $dir,
                'paths_found'  => [
                    'vendor/autoload.php'            => file_exists($dir.'/vendor/autoload.php'),
                    'PHPMailer/src/PHPMailer.php'     => file_exists($dir.'/PHPMailer/src/PHPMailer.php'),
                    'PHPMailer-master/src/PHPMailer.php' => file_exists($dir.'/PHPMailer-master/src/PHPMailer.php'),
                    'PHPMailer/PHPMailer.php'         => file_exists($dir.'/PHPMailer/PHPMailer.php'),
                ],
                'class_exists' => class_exists('PHPMailer\\PHPMailer\\PHPMailer'),
            ]);
            break;
        }
    }

} catch (Throwable $e) {
    error_log('auth.php error: ' . $e->getMessage() . ' in ' . $e->getFile() . ':' . $e->getLine());
    ob_end_clean();
    http_response_code(500);
    header('Content-Type: application/json');
    echo json_encode([
        'success' => false,
        'message' => 'Server error: ' . $e->getMessage(),
    ]);
    exit();
}
