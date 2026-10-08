/// The English copy the 1.2.1 Account screen and the device pairing sheets
/// add on top of `S`.
///
/// It sits apart from `lib/ui/strings.dart` only until the strings for 1.2.1
/// are frozen: then every key here moves into the "Account number" section
/// of `S` under the same name, and the translations start from there. The
/// house rules of `S` apply unchanged: no em dash or en dash, a full stop
/// ends an explanation and never a label, a button or a badge, system
/// explanations in the third person, the imperative only on buttons, and
/// numbers (dates, counts, codes) arrive as parameters.
///
/// Nothing here names a bot, a messenger, a website shop or a price.
abstract final class SA {
  // --- Screen ---------------------------------------------------------------

  /// The screen title. The Settings row moves to the same word.
  static const title = 'Account';

  // --- Status card: does it work, and until when ---------------------------

  static const statusOn = 'Premium is on';
  static const statusOff = 'Premium is off';
  static const statusReplaced = 'Number changed';
  static const statusSignedOut = 'Signed out';
  static const statusRevoked = 'Number no longer valid';

  /// Under "Active until {date}": who keeps it going.
  static String statusRenewsThrough(String store) => 'Renews through $store.';
  static const statusEndsUnlessAdded =
      'Ends on that date unless time is added to the number.';

  static const statusReplacedLine =
      'This account number was changed on another device.';

  /// Only said while Premium really is on here.
  static const statusReplacedStillOn = 'Premium still works on this device.';
  static const statusSignedOutLine =
      'This device was signed out from another device.';
  static const statusSignedOutKept =
      'The number is still kept here, so signing back in takes one tap.';

  static const ctaSignInNewNumber = 'Sign in with the new number';
  static const ctaSignInAnotherNumber = 'Sign in with another number';

  // --- Devices: how do I put it on another device --------------------------

  static const devicesTitle = 'Devices';

  /// "3 of 5", in mono, beside the section label.
  static String devicesCount(int used, int limit) => '$used of $limit';
  static const devicesEmpty = 'No devices are on this account yet.';
  static const devicesFailed = 'The devices could not be loaded.';

  static const addDevice = 'Add a device';
  static const addDeviceSub = 'Phone, tablet, TV, browser or computer';
  static const addDeviceOff =
      'New devices can be added once Premium is on again.';

  /// What a device is, in its row and on the confirmation.
  static const kindPhone = 'Phone';
  static const kindTablet = 'Tablet';
  static const kindTv = 'TV';
  static const kindBrowser = 'Browser';
  static const kindDesktop = 'Desktop';
  static const kindDevice = 'Device';
  static const deviceUnnamed = 'Unnamed device';

  /// The platform a new device reports, by its own name. Null for one this
  /// build does not know, which is then left out rather than shown raw.
  static String? platform(String? wire) => switch (wire) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'chrome' => 'Chrome',
    _ => null,
  };

  // --- Account number ------------------------------------------------------

  static const numberSection = 'Account number';
  static const numberShow = 'Show';
  static const numberNote =
      'The number signs hideip.net in on another device. Anyone with it can '
      'use this Premium, and it cannot be recovered.';
  static const numberNotHere = 'Not on this device';
  static const numberNotHereNote =
      'Entering the number shows it here and lets the other devices use this '
      'Premium.';

  // --- Payment: how do I pay -----------------------------------------------

  static const paymentTitle = 'Payment';

  // --- More options --------------------------------------------------------

  static const moreOptions = 'More options';
  static const rotateSub =
      'Time and devices stay. The old number stops working.';

  // --- Add a device sheet --------------------------------------------------

  static String addShare(int limit) =>
      'Up to $limit devices share this Premium.';
  static String addInUse(int used, int limit) => '$used of $limit are in use.';

  /// The new pairing: the new device shows both, this phone reads either.
  static const addHowV2 =
      'hideip.net on the new device shows a QR code and a short code.';

  /// The 1.2.0 pairing, while the server has nothing newer.
  static const addHowLegacy =
      'A browser or computer shows a QR code that this phone scans.';
  static const scanQr = 'Scan QR code';
  static const scanQrSub = 'The new device is shown here before it is added.';
  static const enterCode = 'Enter code';
  static const enterCodeSub = 'For a TV or computer across the room.';
  static const orSignIn = 'Or sign in on the new device';
  static const signInNote =
      'The account number signs in any device. Anyone with it can use this '
      'Premium.';

  // --- Entering the code the new device shows -------------------------------

  static const codeBody =
      'The code is on the screen of the new device, next to its QR code.';
  static const codeHint = 'XXXX-XXXX';
  static const codeBadChars =
      'This code has a character that hideip.net codes never use. The code '
      'on the new device is worth checking again.';
  static const cameraOff =
      'The camera is turned off for hideip.net in system settings. The code '
      'works the same way.';

  // --- Confirming the new device -------------------------------------------

  static const confirmTitle = 'Add this device?';
  static const confirmCodeLabel = 'Request code';
  static const confirmCodeNote =
      'The same code is on the screen of the new device.';
  static const grantManage = 'Can manage this account';
  static const grantManageSub =
      'It can add and remove devices and change the account number.';
  static const useOnly =
      'This device uses Premium. It cannot manage the '
      'account.';
  static String expiresIn(String time) => 'Expires in $time';
  static const approve = 'Add device';
  static const approving = 'Adding…';
  static const doneTitle = 'Device added';
  static String doneBody(String name) => '$name uses this Premium now.';
  static String doneManage(String name) =>
      '$name can also manage this account.';
  static const done = 'Done';

  // --- No place left -------------------------------------------------------

  static String limitTitle(int limit) => 'All $limit places are in use';
  static const limitBody =
      'Removing a device makes room. This request stays open while it is '
      'valid.';

  // --- Why a pairing step did not go through --------------------------------

  static const errUnknownCode =
      'No request matches this code. The code on the new device is worth '
      'checking, or the new device can show a new one.';
  static const errUnknownLink =
      'This request is no longer open. The new device can show a new QR code.';
  static const errBadCode = 'That is not a hideip.net code.';
  static const errExpired =
      'This request has expired. The new device can show a new code.';
  static const errCancelled = 'The new device cancelled this request.';
  static const errInactive =
      'Premium is off on this account, so no device can be added right now.';
  static const errNotPermitted =
      'This device cannot add or change devices on the account. A device '
      'that manages the account can, and so can the account number.';
  static const errUnauthorized =
      'This device is no longer signed in to the account.';
  static const errUnsupported = 'Adding devices this way is not available yet.';
  static const errSelf = 'A device cannot change its own permissions.';

  // --- The last device that manages the account ----------------------------

  static const lastManagerTitle = 'Last device that manages the account';
  static const lastManagerBody =
      'After this, no device can manage the account. The account number '
      'still can, so it is worth keeping somewhere safe.';

  // --- One device, opened from the list ------------------------------------

  static String deviceAdded(String date) => 'Added $date';
  static String deviceSeen(String date) => 'Last used $date';
  static const deviceNeverUsed = 'Not used yet';
  static const deviceManages = 'Manages the account';
}
