// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get home => 'خانه';

  @override
  String get configs => 'کانفیگ‌ها';

  @override
  String get logs => 'لاگ‌ها';

  @override
  String get overview => 'نمای کلی';

  @override
  String get library => 'کتابخانه';

  @override
  String get account => 'حساب کاربری';

  @override
  String get settings => 'تنظیمات';

  @override
  String get officialProduct => 'نسخه رسمی';

  @override
  String get whiteLabelProduct => 'نسخه اپلیکیشن';

  @override
  String get foundationTitle => 'خدمات امن کلاینت';

  @override
  String get foundationBody =>
      'سیاست محصول، ذخیره‌سازی محافظت‌شده سیستم‌عامل، بومی‌سازی و هماهنگی تونل بومی از یک درخت کد مشترک ترکیب شده‌اند.';

  @override
  String get libraryBody =>
      'اشتراک‌های رسمی و پیکربندی‌های دستی در این بخش و تحت سیاست SDK مدیریت می‌شوند.';

  @override
  String get accountBody =>
      'ثبت اپلیکیشن و دسترسی احراز هویت‌شده فقط در حالت White-label در دسترس است.';

  @override
  String get settingsBody =>
      'اطلاعات امنیت، قابلیت‌های پلتفرم و متن‌باز را بدون نمایش پیکربندی زمان اجرا بررسی کنید.';

  @override
  String get openSourceLicenses => 'مجوزهای متن‌باز';

  @override
  String get openSourceLicensesBody =>
      'اعلامیه‌ها و مجوزهای Flutter و اجزای تونل بومی را بررسی کنید.';

  @override
  String get configurationError => 'پیکربندی این بیلد معتبر نیست.';

  @override
  String get modeLabel => 'حالت محصول';

  @override
  String get secureStorageLabel => 'ذخیره‌سازی امن';

  @override
  String get secureStorageReady =>
      'آداپتور محافظت‌شده سیستم‌عامل پیکربندی شده است';

  @override
  String get nativeTunnelLabel => 'تونل بومی';

  @override
  String get nativeTunnelPending =>
      'دسترسی پروتکل‌ها از آداپتور بومی نصب‌شده روی پلتفرم شناسایی می‌شود.';

  @override
  String get libraryUnavailableTitle => 'کتابخانه رسمی در دسترس نیست';

  @override
  String get libraryUnavailableBody =>
      'سیاست این محصول مخزن پروفایل رسمی را ارائه نمی‌کند.';

  @override
  String get libraryLoadFailed => 'کتابخانه محافظت‌شده باز نشد';

  @override
  String get retry => 'تلاش دوباره';

  @override
  String get libraryEmptyTitle => 'هنوز پروفایلی وجود ندارد';

  @override
  String get libraryEmptyBody =>
      'یک اشتراک اضافه کنید یا پیکربندی دستی پشتیبانی‌شده را وارد کنید. اطلاعات محرمانه فقط در ذخیره‌سازی محافظت‌شده سیستم‌عامل نگهداری می‌شوند.';

  @override
  String get libraryTitle => 'پروفایل‌های VPN';

  @override
  String get libraryDescription =>
      'اشتراک‌های رسمی و پیکربندی‌های دستی پردازش‌شده توسط SDK زاگرس را مدیریت کنید.';

  @override
  String get tunnelUnavailableTitle => 'اتصال در دسترس نیست';

  @override
  String get tunnelUnavailableBody =>
      'آداپتور بومی نصب‌شده از این پیکربندی در پلتفرم فعلی پشتیبانی نمی‌کند.';

  @override
  String get addSubscription => 'افزودن اشتراک';

  @override
  String get addManualConfig => 'افزودن پیکربندی دستی';

  @override
  String get subscriptionRefreshed => 'اشتراک به‌روزرسانی شد.';

  @override
  String get deleteProfileTitle => 'پروفایل حذف شود؟';

  @override
  String deleteProfileBody(String name) {
    return '«$name» و پیکربندی‌های محافظت‌شده آن حذف شوند؟';
  }

  @override
  String get cancel => 'انصراف';

  @override
  String get delete => 'حذف';

  @override
  String get deleted => 'پروفایل حذف شد.';

  @override
  String get edit => 'ویرایش';

  @override
  String get refresh => 'به‌روزرسانی';

  @override
  String get saved => 'پروفایل ذخیره شد.';

  @override
  String get subscriptionProfile => 'اشتراک';

  @override
  String get manualProfile => 'پیکربندی دستی';

  @override
  String profileConfigCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count پیکربندی',
      one: '۱ پیکربندی',
      zero: 'بدون پیکربندی',
    );
    return '$_temp0';
  }

  @override
  String subscriptionHost(String host) {
    return 'منبع: $host';
  }

  @override
  String get protocolWarningPresent => 'هشدار پروتکل';

  @override
  String get configFileBadge => 'فایل';

  @override
  String subscriptionFilesUnavailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فایل دانلودی در دسترس نیست',
      one: '۱ فایل دانلودی در دسترس نیست',
    );
    return '$_temp0';
  }

  @override
  String get profileName => 'نام پروفایل';

  @override
  String get subscriptionUrl => 'نشانی اشتراک';

  @override
  String get rawConfiguration => 'پیکربندی خام';

  @override
  String get subscriptionUrlHelp =>
      'استفاده از HTTPS الزامی است. HTTP فقط برای سرور توسعه loopback پذیرفته می‌شود.';

  @override
  String get manualConfigHelp =>
      'فهرست لینک، WireGuard، OpenVPN، Clash یا پیکربندی sing-box را وارد کنید.';

  @override
  String get editProfile => 'ویرایش پروفایل';

  @override
  String get save => 'ذخیره';

  @override
  String get close => 'بستن';

  @override
  String subscriptionUsage(String used, String total) {
    return 'مصرف‌شده $used از $total';
  }

  @override
  String get unlimited => 'نامحدود';

  @override
  String get viewRawConfig => 'نمایش خام';

  @override
  String get connect => 'اتصال';

  @override
  String get disconnect => 'قطع اتصال';

  @override
  String get rawConfigTitle => 'پیکربندی خام';

  @override
  String get rawConfigSecretWarning =>
      'این پیکربندی شامل اطلاعات ورود است. آن را با افراد غیرقابل‌اعتماد به اشتراک نگذارید.';

  @override
  String get copy => 'کپی';

  @override
  String get export => 'خروجی';

  @override
  String get copied => 'پیکربندی کپی شد.';

  @override
  String get rawActionFailed => 'عملیات محافظت‌شده پیکربندی خام ناموفق بود.';

  @override
  String get exportRawTitle => 'پیکربندی به‌صورت متن ساده صادر شود؟';

  @override
  String get exportRawWarning =>
      'خروجی گرفتن، اطلاعات ورود را در یک فایل متن ساده در محل قابل‌دسترسی کاربر می‌نویسد. پس از استفاده از فایل محافظت کنید یا آن را حذف کنید.';

  @override
  String get exported => 'پیکربندی صادر شد.';

  @override
  String get legacyProtocolWarning =>
      'PPTP قدیمی و ناامن است و در سامانه‌های جدید iOS و Android در دسترس نیست.';

  @override
  String get platformProtocolWarning =>
      'پشتیبانی L2TP به سیستم‌عامل وابسته است و در سامانه‌های جدید iOS و Android محدودیت دارد.';

  @override
  String get genericProtocolWarning =>
      'پیش از اتصال، هشدار این پروتکل را بررسی کنید.';

  @override
  String get libraryValidationFailed =>
      'نام پروفایل، نشانی یا پیکربندی معتبر نیست.';

  @override
  String get libraryAccessDenied => 'سرور یا سیاست محصول این عملیات را رد کرد.';

  @override
  String get libraryNetworkFailed =>
      'دسترسی به اشتراک ممکن نشد. پروفایل قبلی حفظ شد.';

  @override
  String get libraryStorageFailed =>
      'ذخیره‌سازی محافظت‌شده سیستم‌عامل در دسترس نیست. از جایگزین متن ساده استفاده نشد.';

  @override
  String get libraryMalformedFailed =>
      'پیکربندی یا فهرست محافظت‌شده نامعتبر است.';

  @override
  String get libraryUnknownFailed => 'عملیات تکمیل نشد.';

  @override
  String get protocolUnavailableTitle => 'پروتکل در دسترس نیست';

  @override
  String protocolUnavailableBody(String protocol) {
    return 'آداپتور تونل نصب‌شده از $protocol پشتیبانی نمی‌کند.';
  }

  @override
  String get connectionRequestedTitle => 'درخواست اتصال ارسال شد';

  @override
  String get connectionRequestedBody =>
      'آداپتور بومی درخواست را پذیرفت، اما هنوز وضعیت متصل را تأیید نکرده است.';

  @override
  String get connectedTitle => 'متصل شد';

  @override
  String get connectedBody => 'آداپتور بومی اتصال تونل را تأیید کرد.';

  @override
  String get connectionFailedTitle => 'اتصال ناموفق بود';

  @override
  String get connectionFailedBody => 'آداپتور تونل بومی درخواست را رد کرد.';

  @override
  String get ok => 'تأیید';

  @override
  String get enrollTitle => 'ثبت این دستگاه';

  @override
  String get loginTitle => 'ورود';

  @override
  String get usernameLabel => 'نام کاربری';

  @override
  String get passwordLabel => 'گذرواژه';

  @override
  String get activationCodeLabel => 'کد فعال‌سازی';

  @override
  String get enrollAction => 'ثبت دستگاه';

  @override
  String get loginAction => 'ورود';

  @override
  String get logoutAction => 'خروج';

  @override
  String get reEnrollAction => 'استفاده از کد فعال‌سازی دیگر';

  @override
  String get configsTitle => 'اتصال‌ها';

  @override
  String get usageTitle => 'مصرف';

  @override
  String get available => 'در دسترس';

  @override
  String get unavailable => 'در دسترس نیست';

  @override
  String activeConnectionsCount(int count) {
    return 'اتصال‌های فعال: $count';
  }

  @override
  String signedInAs(String username) {
    return 'واردشده به‌عنوان $username';
  }

  @override
  String get noConfigsTitle => 'اتصالی در دسترس نیست';

  @override
  String get noConfigsBody =>
      'سرور برای این حساب هیچ پیکربندی قابل اتصالی برنگرداند.';

  @override
  String get serviceUnavailableTitle => 'حساب در دسترس نیست';

  @override
  String get serviceUnavailableBody =>
      'سرویس اپلیکیشن راه‌اندازی نشد. ممکن است حافظه امن سیستم‌عامل در دسترس نباشد.';

  @override
  String get alreadyConnectedTitle => 'در حال حاضر متصل است';

  @override
  String get alreadyConnectedBody =>
      'پیش از شروع اتصال دیگر، اتصال فعال را قطع کنید.';

  @override
  String get errorEnrollInput =>
      'نام کاربری، گذرواژه و کد فعال‌سازی را وارد کنید.';

  @override
  String get errorLoginInput => 'نام کاربری و گذرواژه را وارد کنید.';

  @override
  String get errorInvalidCredentials => 'نام کاربری یا گذرواژه نادرست است.';

  @override
  String get errorTicketInvalid => 'کد فعال‌سازی نامعتبر است یا منقضی شده است.';

  @override
  String get errorAccessDenied => 'این حساب یا دستگاه اجازه اتصال ندارد.';

  @override
  String get errorSessionExpired => 'نشست منقضی شد. دوباره وارد شوید.';

  @override
  String get errorEnrollmentRequired =>
      'این دستگاه دیگر ثبت نشده است. یک کد فعال‌سازی جدید وارد کنید.';

  @override
  String get errorNetwork =>
      'سرور در دسترس نیست. اتصال را بررسی کنید و دوباره تلاش کنید.';

  @override
  String get errorRateLimited =>
      'تلاش‌ها بیش از حد مجاز است. کمی صبر کنید و دوباره تلاش کنید.';

  @override
  String get errorStorage =>
      'حافظه امن سیستم‌عامل در دسترس نیست. از هیچ جایگزین متن ساده استفاده نشد.';

  @override
  String get errorUnknown => 'عملیات تکمیل نشد.';

  @override
  String get speedDownload => 'دانلود';

  @override
  String get speedUpload => 'آپلود';

  @override
  String get statusDisconnected => 'قطع شده';

  @override
  String get statusConnecting => 'در حال اتصال...';

  @override
  String get statusConnected => 'متصل';

  @override
  String get statusDisconnecting => 'در حال قطع اتصال...';

  @override
  String get statusFailed => 'خطا در اتصال';

  @override
  String get noActiveConfig => 'هیچ کانفیگی انتخاب نشده';

  @override
  String get selectConfigToConnect => 'یک کانفیگ برای اتصال انتخاب کنید';

  @override
  String get comingSoon => 'به‌زودی';

  @override
  String get unsupportedProtocol => 'پشتیبانی‌نشده';

  @override
  String get protocolNotImplemented =>
      'موتور این پروتکل در این نسخه ارائه نشده و در به‌روزرسانی‌های آینده فعال خواهد شد.';

  @override
  String get clearLogs => 'پاکسازی لاگ‌ها';

  @override
  String get copyLogs => 'کپی لاگ‌ها';

  @override
  String get logsCopied => 'لاگ‌ها در حافظه کپی شدند.';

  @override
  String get noLogsYet => 'هنوز لاگی ثبت نشده است.';

  @override
  String get language => 'زبان';

  @override
  String get persian => 'فارسی';

  @override
  String get english => 'English';

  @override
  String get dnsSettings => 'تنظیمات DNS';

  @override
  String get dnsSystem => 'پیش‌فرض سیستم';

  @override
  String get dnsCloudflare => 'کلودفلر (1.1.1.1)';

  @override
  String get dnsGoogle => 'گوگل (8.8.8.8)';

  @override
  String get dnsCustom => 'DNS سفارشی';

  @override
  String get customDnsAddress => 'سرور DNS سفارشی';

  @override
  String get fakeDnsTitle => 'DNS فیک';

  @override
  String get fakeDnsSubtitle =>
      'دامنه‌ها از یک استخر آدرس مصنوعی جواب می‌گیرند (اتصال سریع‌تر)؛ آدرس واقعی داخل تونل بازسازی می‌شود.';

  @override
  String get perAppTitle => 'پروکسی بر اساس برنامه';

  @override
  String get perAppSubtitle =>
      'انتخاب کنید کدام برنامه‌ها از تونل VPN عبور کنند.';

  @override
  String get perAppAllowMode => 'فقط برنامه‌های انتخاب‌شده از VPN عبور کنند';

  @override
  String get perAppDenyMode => 'برنامه‌های انتخاب‌شده از VPN عبور نکنند';

  @override
  String get perAppSelectApps => 'انتخاب برنامه‌ها';

  @override
  String get perAppSearch => 'جست‌وجوی برنامه‌ها';

  @override
  String perAppSelectedCount(int count) {
    return '$count برنامه انتخاب شد';
  }

  @override
  String get perAppNoApps => 'برنامه‌ای یافت نشد';

  @override
  String get perAppClearAll => 'پاک‌کردن';

  @override
  String get perAppAppliesNextConnect => 'در اتصال بعدی اعمال می‌شود.';

  @override
  String get ping => 'پینگ';

  @override
  String get ms => 'میلی‌ثانیه';

  @override
  String get accountInfo => 'اطلاعات حساب';

  @override
  String get tapToConnect => 'برای اتصال لمس کنید';

  @override
  String get tapToDisconnect => 'برای قطع اتصال لمس کنید';

  @override
  String get activeConfigLabel => 'سرور فعال';

  @override
  String get subscriptionsSection => 'اشتراک‌ها';

  @override
  String get localConfigsSection => 'Local (پیکربندی‌های محلی)';

  @override
  String subscriptionRemaining(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days روز مانده',
      one: '۱ روز مانده',
      zero: 'انقضا امروز',
    );
    return '$_temp0';
  }

  @override
  String subscriptionExpires(String date) {
    return 'انقضا: $date';
  }

  @override
  String subscriptionUpdateInterval(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours ساعت',
      one: '۱ ساعت',
    );
    return 'فاصله پیشنهادی به‌روزرسانی: $_temp0';
  }

  @override
  String subscriptionLastRefreshed(String date) {
    return 'آخرین به‌روزرسانی: $date';
  }
}
