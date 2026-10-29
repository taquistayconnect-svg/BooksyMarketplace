-- ============================================================================
-- General-Purpose Service Marketplace
-- PostgreSQL 15+ | PascalCase identifiers | Explicit FKs, indexes and enums
--
-- Terminology:
--   Seller = a person/business offering services or reservable goods.
--   Store  = a seller's operating location (physical, virtual, mobile, hybrid).
--   Staff  = people working for a seller.
--   Customer = person making bookings/purchases.
--
-- Run in a NEW database using pgAdmin 4 Query Tool.
-- This is a production-oriented baseline, not a substitute for review against
-- jurisdiction-specific tax, privacy, employment, and payment requirements.
--
-- Important:
-- * Store business timestamps in TIMESTAMPTZ; store each Store's IANA TimeZone.
-- * Never store raw card numbers/CVV. Store payment-provider references/tokens.
-- * Keep BookingStatus separate from PaymentStatus.
-- * Booking overlap prevention must be enforced transactionally; this schema
--   includes a GiST exclusion constraint for exclusive resource reservations.
--   Capacity-based services need explicit capacity accounting in the API.
-- * All mutable business tables use CreatedAt/CreatedBy/UpdatedAt/UpdatedBy.
--   Deletion is soft-delete where operational history should be retained.
-- ============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============================================================================
-- ENUMS
-- ============================================================================
CREATE TYPE "UserStatus" AS ENUM ('PendingVerification','Active','Suspended','Disabled','Deleted');
CREATE TYPE "SellerType" AS ENUM ('Individual','Business','NonProfit','PublicOrganization');
CREATE TYPE "SellerStatus" AS ENUM ('Draft','PendingReview','Active','Suspended','Closed');
CREATE TYPE "MembershipStatus" AS ENUM ('Invited','Active','Suspended','Removed');
CREATE TYPE "StoreType" AS ENUM ('Physical','MobileService','Virtual','Hybrid','ResourceOnly');
CREATE TYPE "StoreStatus" AS ENUM ('Draft','PendingReview','Active','TemporarilyClosed','Suspended','Closed');
CREATE TYPE "VisibilityStatus" AS ENUM ('Private','Unlisted','Public');
CREATE TYPE "MediaType" AS ENUM ('Image','Video','Document','Other');
CREATE TYPE "ServiceDeliveryType" AS ENUM ('InPersonAtStore','AtCustomerLocation','Remote','Hybrid');
CREATE TYPE "BookingModel" AS ENUM ('Appointment','CapacitySession','ResourceReservation','DateRangeReservation','FixedEvent');
CREATE TYPE "PriceType" AS ENUM ('Fixed','StartingAt','Hourly','Daily','PerUnit','QuoteRequired','Free');
CREATE TYPE "ServiceStatus" AS ENUM ('Draft','Active','Paused','Archived');
CREATE TYPE "BookingStatus" AS ENUM ('Draft','PendingPayment','PendingApproval','Confirmed','CheckedIn','InProgress','Completed','Cancelled','Rejected','NoShow','Expired');
CREATE TYPE "BookingItemStatus" AS ENUM ('Pending','Confirmed','InProgress','Completed','Cancelled','NoShow');
CREATE TYPE "BookingSource" AS ENUM ('MarketplaceWeb','MarketplaceMobile','SellerDashboard','Admin','ExternalIntegration','Phone','WalkIn');
CREATE TYPE "CancellationActorType" AS ENUM ('Customer','Seller','Staff','Admin','System');
CREATE TYPE "PaymentStatus" AS ENUM ('RequiresPaymentMethod','RequiresConfirmation','Pending','Authorized','PartiallyPaid','Paid','PartiallyRefunded','Refunded','Failed','Cancelled','Disputed');
CREATE TYPE "PaymentMethodType" AS ENUM ('Card','Wallet','BankTransfer','Cash','GiftCard','BuyNowPayLater','Other');
CREATE TYPE "PaymentPurpose" AS ENUM ('Deposit','BookingBalance','FullBooking','Tip','Order','Membership','Package','CancellationFee','Other');
CREATE TYPE "RefundStatus" AS ENUM ('Pending','Processing','Succeeded','Failed','Cancelled');
CREATE TYPE "PayoutStatus" AS ENUM ('Pending','Processing','Paid','Failed','Cancelled','OnHold');
CREATE TYPE "OrderStatus" AS ENUM ('Draft','PendingPayment','Paid','PartiallyFulfilled','Fulfilled','Cancelled','PartiallyRefunded','Refunded');
CREATE TYPE "OrderItemType" AS ENUM ('Service','Product','Package','GiftCard','Membership','Fee','Other');
CREATE TYPE "ProductStatus" AS ENUM ('Draft','Active','Paused','Archived');
CREATE TYPE "InventoryMovementType" AS ENUM ('InitialStock','Purchase','Sale','Return','Adjustment','Damage','TransferIn','TransferOut','ServiceConsumption');
CREATE TYPE "DiscountType" AS ENUM ('Percentage','FixedAmount');
CREATE TYPE "PromotionStatus" AS ENUM ('Draft','Scheduled','Active','Paused','Expired','Archived');
CREATE TYPE "GiftCardStatus" AS ENUM ('Pending','Active','FullyRedeemed','Expired','Cancelled','Suspended');
CREATE TYPE "PackageStatus" AS ENUM ('Draft','Active','Paused','Expired','Archived');
CREATE TYPE "MembershipPlanStatus" AS ENUM ('Draft','Active','Paused','Archived');
CREATE TYPE "SubscriptionStatus" AS ENUM ('Trialing','Active','PastDue','Paused','Cancelled','Expired');
CREATE TYPE "ReviewStatus" AS ENUM ('Pending','Published','Hidden','Rejected','Removed');
CREATE TYPE "ReportStatus" AS ENUM ('Open','UnderReview','Actioned','Dismissed','Closed');
CREATE TYPE "NotificationChannel" AS ENUM ('Email','Sms','Push','InApp','Webhook');
CREATE TYPE "NotificationStatus" AS ENUM ('Queued','Processing','Sent','Delivered','Failed','Cancelled');
CREATE TYPE "OutboxStatus" AS ENUM ('Pending','Processing','Published','Failed');
CREATE TYPE "SupportTicketStatus" AS ENUM ('Open','InProgress','WaitingForCustomer','WaitingForSeller','Resolved','Closed');
CREATE TYPE "SupportPriority" AS ENUM ('Low','Normal','High','Urgent');
CREATE TYPE "FilePurpose" AS ENUM ('Avatar','SellerLogo','StoreCover','Portfolio','ServiceMedia','CustomerAttachment','FormAttachment','Other');
CREATE TYPE "ConsentType" AS ENUM ('TermsOfService','PrivacyPolicy','MarketingEmail','MarketingSms','Cookies','DataProcessing');
CREATE TYPE "IntegrationStatus" AS ENUM ('Pending','Connected','Error','Disconnected','Disabled');
CREATE TYPE "WebhookDeliveryStatus" AS ENUM ('Pending','Delivered','Failed','Abandoned');
CREATE TYPE "WaitlistStatus" AS ENUM ('Waiting','Offered','Booked','Expired','Cancelled');
CREATE TYPE "FormStatus" AS ENUM ('Draft','Published','Archived');
CREATE TYPE "FormResponseStatus" AS ENUM ('InProgress','Submitted','Reviewed','Rejected');
CREATE TYPE "AuditAction" AS ENUM ('Insert','Update','Delete','Login','Logout','PermissionChange','Export','Other');

-- ============================================================================
-- USERS, AUTHENTICATION, ROLES, PERMISSIONS
-- ============================================================================
CREATE TABLE "Users" (
 "UserId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "Email" CITEXT NOT NULL UNIQUE,
 "PhoneNumber" VARCHAR(32),
 "PasswordHash" TEXT,
 "Status" "UserStatus" NOT NULL DEFAULT 'PendingVerification',
 "EmailVerifiedAt" TIMESTAMPTZ,
 "PhoneVerifiedAt" TIMESTAMPTZ,
 "LastLoginAt" TIMESTAMPTZ,
 "PreferredLanguage" VARCHAR(16) NOT NULL DEFAULT 'en',
 "TimeZone" VARCHAR(64) NOT NULL DEFAULT 'UTC',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID,
 "DeletedAt" TIMESTAMPTZ,
 "DeletedBy" UUID,
 CONSTRAINT "CK_Users_Email" CHECK (length(trim("Email"::text)) > 3),
 CONSTRAINT "FK_Users_CreatedBy" FOREIGN KEY ("CreatedBy") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Users_UpdatedBy" FOREIGN KEY ("UpdatedBy") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Users_DeletedBy" FOREIGN KEY ("DeletedBy") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_Users_Status" ON "Users"("Status") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_Users_Phone" ON "Users"("PhoneNumber") WHERE "PhoneNumber" IS NOT NULL AND "DeletedAt" IS NULL;

CREATE TABLE "UserProfiles" (
 "UserId" UUID PRIMARY KEY,
 "FirstName" VARCHAR(100) NOT NULL,
 "LastName" VARCHAR(100),
 "DisplayName" VARCHAR(200),
 "DateOfBirth" DATE,
 "AvatarUrl" TEXT,
 "Bio" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_UserProfiles_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE
);

CREATE TABLE "Roles" (
 "RoleId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "RoleCode" VARCHAR(80) NOT NULL UNIQUE,
 "RoleName" VARCHAR(120) NOT NULL,
 "Description" TEXT,
 "IsSystemRole" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE TABLE "Permissions" (
 "PermissionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "PermissionCode" VARCHAR(120) NOT NULL UNIQUE,
 "PermissionName" VARCHAR(160) NOT NULL,
 "ModuleName" VARCHAR(80) NOT NULL,
 "Description" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_Permissions_Module" ON "Permissions"("ModuleName");
CREATE TABLE "RolePermissions" (
 "RoleId" UUID NOT NULL,
 "PermissionId" UUID NOT NULL,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("RoleId","PermissionId"),
 CONSTRAINT "FK_RolePermissions_Role" FOREIGN KEY ("RoleId") REFERENCES "Roles"("RoleId") ON DELETE CASCADE,
 CONSTRAINT "FK_RolePermissions_Permission" FOREIGN KEY ("PermissionId") REFERENCES "Permissions"("PermissionId") ON DELETE CASCADE
);
CREATE TABLE "UserRoles" (
 "UserId" UUID NOT NULL,
 "RoleId" UUID NOT NULL,
 "AssignedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "AssignedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("UserId","RoleId"),
 CONSTRAINT "FK_UserRoles_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "FK_UserRoles_Role" FOREIGN KEY ("RoleId") REFERENCES "Roles"("RoleId") ON DELETE CASCADE
);
CREATE INDEX "IX_UserRoles_Role" ON "UserRoles"("RoleId");
CREATE TABLE "UserSessions" (
 "SessionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "UserId" UUID NOT NULL,
 "TokenHash" TEXT NOT NULL UNIQUE,
 "ExpiresAt" TIMESTAMPTZ NOT NULL,
 "RevokedAt" TIMESTAMPTZ,
 "IpAddress" INET,
 "UserAgent" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_UserSessions_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE
);
CREATE INDEX "IX_UserSessions_UserExpiry" ON "UserSessions"("UserId","ExpiresAt");
CREATE INDEX "IX_UserSessions_Expiry" ON "UserSessions"("ExpiresAt") WHERE "RevokedAt" IS NULL;
CREATE TABLE "UserAddresses" (
 "AddressId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "UserId" UUID NOT NULL,
 "AddressLabel" VARCHAR(80),
 "AddressLine1" VARCHAR(200) NOT NULL,
 "AddressLine2" VARCHAR(200),
 "City" VARCHAR(120) NOT NULL,
 "StateOrProvince" VARCHAR(120),
 "PostalCode" VARCHAR(32),
 "CountryCode" CHAR(2) NOT NULL,
 "Latitude" NUMERIC(9,6),
 "Longitude" NUMERIC(9,6),
 "IsDefault" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_UserAddresses_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "CK_UserAddresses_Latitude" CHECK ("Latitude" IS NULL OR "Latitude" BETWEEN -90 AND 90),
 CONSTRAINT "CK_UserAddresses_Longitude" CHECK ("Longitude" IS NULL OR "Longitude" BETWEEN -180 AND 180)
);
CREATE INDEX "IX_UserAddresses_User" ON "UserAddresses"("UserId");
CREATE INDEX "IX_UserAddresses_CityCountry" ON "UserAddresses"("City","CountryCode");
CREATE TABLE "UserConsents" (
 "ConsentId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "UserId" UUID NOT NULL,
 "ConsentType" "ConsentType" NOT NULL,
 "Granted" BOOLEAN NOT NULL,
 "PolicyVersion" VARCHAR(40) NOT NULL,
 "RecordedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "IpAddress" INET,
 "UserAgent" TEXT,
 CONSTRAINT "FK_UserConsents_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE
);
CREATE INDEX "IX_UserConsents_UserTypeDate" ON "UserConsents"("UserId","ConsentType","RecordedAt" DESC);

-- ============================================================================
-- SELLERS, STORES, TEAM MEMBERS, CATEGORIES, MEDIA
-- ============================================================================
CREATE TABLE "Sellers" (
 "SellerId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "OwnerUserId" UUID NOT NULL,
 "SellerType" "SellerType" NOT NULL,
 "LegalName" VARCHAR(200) NOT NULL,
 "DisplayName" VARCHAR(200) NOT NULL,
 "Slug" CITEXT NOT NULL UNIQUE,
 "Description" TEXT,
 "Email" CITEXT,
 "PhoneNumber" VARCHAR(32),
 "WebsiteUrl" TEXT,
 "TaxIdentifier" VARCHAR(100),
 "RegistrationNumber" VARCHAR(100),
 "DefaultCurrency" CHAR(3) NOT NULL DEFAULT 'INR',
 "Status" "SellerStatus" NOT NULL DEFAULT 'Draft',
 "Visibility" "VisibilityStatus" NOT NULL DEFAULT 'Private',
 "VerifiedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 "DeletedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Sellers_Owner" FOREIGN KEY ("OwnerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT
);
CREATE INDEX "IX_Sellers_Owner" ON "Sellers"("OwnerUserId");
CREATE INDEX "IX_Sellers_StatusVisibility" ON "Sellers"("Status","Visibility") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_Sellers_DisplayNameTrgm" ON "Sellers" USING GIN ("DisplayName" gin_trgm_ops);

CREATE TABLE "SellerMembers" (
 "SellerMemberId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "UserId" UUID NOT NULL,
 "RoleCode" VARCHAR(80) NOT NULL DEFAULT 'Staff',
 "Status" "MembershipStatus" NOT NULL DEFAULT 'Invited',
 "InvitedAt" TIMESTAMPTZ,
 "JoinedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_SellerMembers_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_SellerMembers_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "UQ_SellerMembers_SellerUser" UNIQUE ("SellerId","UserId")
);
CREATE INDEX "IX_SellerMembers_UserStatus" ON "SellerMembers"("UserId","Status");
CREATE INDEX "IX_SellerMembers_SellerStatus" ON "SellerMembers"("SellerId","Status");

CREATE TABLE "Stores" (
 "StoreId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreName" VARCHAR(200) NOT NULL,
 "Slug" CITEXT NOT NULL,
 "StoreType" "StoreType" NOT NULL DEFAULT 'Physical',
 "Status" "StoreStatus" NOT NULL DEFAULT 'Draft',
 "Visibility" "VisibilityStatus" NOT NULL DEFAULT 'Private',
 "Description" TEXT,
 "Email" CITEXT,
 "PhoneNumber" VARCHAR(32),
 "WebsiteUrl" TEXT,
 "TimeZone" VARCHAR(64) NOT NULL DEFAULT 'UTC',
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "AddressLine1" VARCHAR(200),
 "AddressLine2" VARCHAR(200),
 "City" VARCHAR(120),
 "StateOrProvince" VARCHAR(120),
 "PostalCode" VARCHAR(32),
 "CountryCode" CHAR(2),
 "Latitude" NUMERIC(9,6),
 "Longitude" NUMERIC(9,6),
 "ServiceRadiusKm" NUMERIC(8,2),
 "BookingLeadMinutes" INTEGER NOT NULL DEFAULT 0,
 "BookingHorizonDays" INTEGER NOT NULL DEFAULT 90,
 "CancellationWindowMinutes" INTEGER NOT NULL DEFAULT 1440,
 "PublicBookingEnabled" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 "DeletedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Stores_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "UQ_Stores_SellerSlug" UNIQUE ("SellerId","Slug"),
 CONSTRAINT "CK_Stores_BookingRules" CHECK ("BookingLeadMinutes" >= 0 AND "BookingHorizonDays" > 0 AND "CancellationWindowMinutes" >= 0),
 CONSTRAINT "CK_Stores_Latitude" CHECK ("Latitude" IS NULL OR "Latitude" BETWEEN -90 AND 90),
 CONSTRAINT "CK_Stores_Longitude" CHECK ("Longitude" IS NULL OR "Longitude" BETWEEN -180 AND 180)
);
CREATE INDEX "IX_Stores_SellerStatus" ON "Stores"("SellerId","Status") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_Stores_CityCountry" ON "Stores"("CountryCode","StateOrProvince","City") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_Stores_NameTrgm" ON "Stores" USING GIN ("StoreName" gin_trgm_ops);
CREATE INDEX "IX_Stores_Location" ON "Stores"("Latitude","Longitude") WHERE "Latitude" IS NOT NULL AND "Longitude" IS NOT NULL;

CREATE TABLE "Categories" (
 "CategoryId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ParentCategoryId" UUID,
 "CategoryCode" CITEXT NOT NULL UNIQUE,
 "Name" VARCHAR(160) NOT NULL,
 "Slug" CITEXT NOT NULL UNIQUE,
 "Description" TEXT,
 "IconUrl" TEXT,
 "SortOrder" INTEGER NOT NULL DEFAULT 0,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Categories_Parent" FOREIGN KEY ("ParentCategoryId") REFERENCES "Categories"("CategoryId") ON DELETE SET NULL,
 CONSTRAINT "CK_Categories_NotSelfParent" CHECK ("ParentCategoryId" IS NULL OR "ParentCategoryId" <> "CategoryId")
);
CREATE INDEX "IX_Categories_ParentSort" ON "Categories"("ParentCategoryId","SortOrder") WHERE "IsActive";
CREATE TABLE "SellerCategories" (
 "SellerId" UUID NOT NULL,
 "CategoryId" UUID NOT NULL,
 "IsPrimary" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("SellerId","CategoryId"),
 CONSTRAINT "FK_SellerCategories_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_SellerCategories_Category" FOREIGN KEY ("CategoryId") REFERENCES "Categories"("CategoryId") ON DELETE RESTRICT
);
CREATE INDEX "IX_SellerCategories_Category" ON "SellerCategories"("CategoryId","SellerId");

CREATE TABLE "Files" (
 "FileId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "OwnerUserId" UUID,
 "SellerId" UUID,
 "StoreId" UUID,
 "FilePurpose" "FilePurpose" NOT NULL DEFAULT 'Other',
 "MediaType" "MediaType" NOT NULL DEFAULT 'Other',
 "StorageProvider" VARCHAR(40) NOT NULL,
 "StorageObjectKey" TEXT NOT NULL,
 "OriginalFileName" VARCHAR(255),
 "ContentType" VARCHAR(150),
 "SizeBytes" BIGINT NOT NULL,
 "ChecksumSha256" CHAR(64),
 "IsPublic" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Files_Owner" FOREIGN KEY ("OwnerUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Files_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_Files_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "CK_Files_Size" CHECK ("SizeBytes" >= 0),
 CONSTRAINT "UQ_Files_StorageObject" UNIQUE ("StorageProvider","StorageObjectKey")
);
CREATE INDEX "IX_Files_SellerPurpose" ON "Files"("SellerId","FilePurpose");
CREATE INDEX "IX_Files_Owner" ON "Files"("OwnerUserId") WHERE "OwnerUserId" IS NOT NULL;

CREATE TABLE "StoreHours" (
 "StoreHourId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "StoreId" UUID NOT NULL,
 "DayOfWeek" SMALLINT NOT NULL,
 "OpensAt" TIME NOT NULL,
 "ClosesAt" TIME NOT NULL,
 "IsClosed" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_StoreHours_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "CK_StoreHours_Day" CHECK ("DayOfWeek" BETWEEN 0 AND 6),
 CONSTRAINT "CK_StoreHours_Time" CHECK ("IsClosed" OR "OpensAt" < "ClosesAt")
);
CREATE INDEX "IX_StoreHours_StoreDay" ON "StoreHours"("StoreId","DayOfWeek");

-- ============================================================================
-- STAFF, RESOURCES, SERVICES AND AVAILABILITY
-- ============================================================================
CREATE TABLE "StaffMembers" (
 "StaffMemberId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "UserId" UUID,
 "DisplayName" VARCHAR(160) NOT NULL,
 "Email" CITEXT,
 "PhoneNumber" VARCHAR(32),
 "Bio" TEXT,
 "AvatarFileId" UUID,
 "IsBookable" BOOLEAN NOT NULL DEFAULT TRUE,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "DefaultCommissionRate" NUMERIC(5,2),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 CONSTRAINT "FK_StaffMembers_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_StaffMembers_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_StaffMembers_Avatar" FOREIGN KEY ("AvatarFileId") REFERENCES "Files"("FileId") ON DELETE SET NULL,
 CONSTRAINT "CK_StaffMembers_Commission" CHECK ("DefaultCommissionRate" IS NULL OR "DefaultCommissionRate" BETWEEN 0 AND 100)
);
CREATE INDEX "IX_StaffMembers_SellerActive" ON "StaffMembers"("SellerId","IsActive") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_StaffMembers_User" ON "StaffMembers"("UserId") WHERE "UserId" IS NOT NULL;

CREATE TABLE "StaffStores" (
 "StaffMemberId" UUID NOT NULL,
 "StoreId" UUID NOT NULL,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("StaffMemberId","StoreId"),
 CONSTRAINT "FK_StaffStores_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE CASCADE,
 CONSTRAINT "FK_StaffStores_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE
);
CREATE INDEX "IX_StaffStores_Store" ON "StaffStores"("StoreId","StaffMemberId");

CREATE TABLE "StaffSchedules" (
 "StaffScheduleId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "StaffMemberId" UUID NOT NULL,
 "StoreId" UUID NOT NULL,
 "DayOfWeek" SMALLINT NOT NULL,
 "StartsAt" TIME NOT NULL,
 "EndsAt" TIME NOT NULL,
 "EffectiveFrom" DATE,
 "EffectiveTo" DATE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_StaffSchedules_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE CASCADE,
 CONSTRAINT "FK_StaffSchedules_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "CK_StaffSchedules_Day" CHECK ("DayOfWeek" BETWEEN 0 AND 6),
 CONSTRAINT "CK_StaffSchedules_Time" CHECK ("StartsAt" < "EndsAt"),
 CONSTRAINT "CK_StaffSchedules_Dates" CHECK ("EffectiveTo" IS NULL OR "EffectiveFrom" IS NULL OR "EffectiveTo" >= "EffectiveFrom")
);
CREATE INDEX "IX_StaffSchedules_StaffDay" ON "StaffSchedules"("StaffMemberId","DayOfWeek");
CREATE INDEX "IX_StaffSchedules_StoreDay" ON "StaffSchedules"("StoreId","DayOfWeek");

CREATE TABLE "ScheduleExceptions" (
 "ScheduleExceptionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "StaffMemberId" UUID,
 "StartsAt" TIMESTAMPTZ NOT NULL,
 "EndsAt" TIMESTAMPTZ NOT NULL,
 "IsAvailable" BOOLEAN NOT NULL DEFAULT FALSE,
 "Reason" VARCHAR(250),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ScheduleExceptions_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_ScheduleExceptions_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "FK_ScheduleExceptions_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE CASCADE,
 CONSTRAINT "CK_ScheduleExceptions_Interval" CHECK ("StartsAt" < "EndsAt")
);
CREATE INDEX "IX_ScheduleExceptions_SellerTime" ON "ScheduleExceptions"("SellerId","StartsAt","EndsAt");
CREATE INDEX "IX_ScheduleExceptions_StaffTime" ON "ScheduleExceptions"("StaffMemberId","StartsAt","EndsAt") WHERE "StaffMemberId" IS NOT NULL;

CREATE TABLE "Resources" (
 "ResourceId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "ResourceName" VARCHAR(160) NOT NULL,
 "ResourceType" VARCHAR(80) NOT NULL,
 "Description" TEXT,
 "Capacity" INTEGER NOT NULL DEFAULT 1,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Resources_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_Resources_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "CK_Resources_Capacity" CHECK ("Capacity" > 0)
);
CREATE INDEX "IX_Resources_SellerStoreActive" ON "Resources"("SellerId","StoreId","IsActive");

CREATE TABLE "ServiceDefinitions" (
 "ServiceDefinitionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CategoryId" UUID,
 "ServiceName" VARCHAR(200) NOT NULL,
 "Slug" CITEXT NOT NULL UNIQUE,
 "Description" TEXT,
 "DefaultBookingModel" "BookingModel" NOT NULL DEFAULT 'Appointment',
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ServiceDefinitions_Category" FOREIGN KEY ("CategoryId") REFERENCES "Categories"("CategoryId") ON DELETE SET NULL
);
CREATE INDEX "IX_ServiceDefinitions_CategoryActive" ON "ServiceDefinitions"("CategoryId","IsActive");
CREATE INDEX "IX_ServiceDefinitions_NameTrgm" ON "ServiceDefinitions" USING GIN ("ServiceName" gin_trgm_ops);

CREATE TABLE "SellerServices" (
 "SellerServiceId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "ServiceDefinitionId" UUID,
 "ServiceName" VARCHAR(200) NOT NULL,
 "Slug" CITEXT NOT NULL,
 "Description" TEXT,
 "BookingModel" "BookingModel" NOT NULL DEFAULT 'Appointment',
 "DeliveryType" "ServiceDeliveryType" NOT NULL DEFAULT 'InPersonAtStore',
 "PriceType" "PriceType" NOT NULL DEFAULT 'Fixed',
 "BasePrice" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "DurationMinutes" INTEGER,
 "ProcessingMinutes" INTEGER NOT NULL DEFAULT 0,
 "BufferBeforeMinutes" INTEGER NOT NULL DEFAULT 0,
 "BufferAfterMinutes" INTEGER NOT NULL DEFAULT 0,
 "Capacity" INTEGER NOT NULL DEFAULT 1,
 "RequiresApproval" BOOLEAN NOT NULL DEFAULT FALSE,
 "RequiresDeposit" BOOLEAN NOT NULL DEFAULT FALSE,
 "DepositAmount" NUMERIC(12,2),
 "DepositPercent" NUMERIC(5,2),
 "MinimumNoticeMinutes" INTEGER NOT NULL DEFAULT 0,
 "MaximumAdvanceDays" INTEGER NOT NULL DEFAULT 90,
 "CancellationWindowMinutes" INTEGER NOT NULL DEFAULT 1440,
 "CancellationFee" NUMERIC(12,2),
 "TravelRadiusKm" NUMERIC(8,2),
 "TravelFee" NUMERIC(12,2),
 "Status" "ServiceStatus" NOT NULL DEFAULT 'Draft',
 "SortOrder" INTEGER NOT NULL DEFAULT 0,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 CONSTRAINT "FK_SellerServices_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_SellerServices_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "FK_SellerServices_Definition" FOREIGN KEY ("ServiceDefinitionId") REFERENCES "ServiceDefinitions"("ServiceDefinitionId") ON DELETE SET NULL,
 CONSTRAINT "UQ_SellerServices_SellerSlug" UNIQUE ("SellerId","Slug"),
 CONSTRAINT "CK_SellerServices_Price" CHECK ("BasePrice" >= 0 AND ("DepositAmount" IS NULL OR "DepositAmount" >= 0) AND ("CancellationFee" IS NULL OR "CancellationFee" >= 0)),
 CONSTRAINT "CK_SellerServices_Duration" CHECK (("DurationMinutes" IS NULL OR "DurationMinutes" > 0) AND "ProcessingMinutes" >= 0 AND "BufferBeforeMinutes" >= 0 AND "BufferAfterMinutes" >= 0),
 CONSTRAINT "CK_SellerServices_Capacity" CHECK ("Capacity" > 0),
 CONSTRAINT "CK_SellerServices_Deposit" CHECK ("DepositPercent" IS NULL OR "DepositPercent" BETWEEN 0 AND 100),
 CONSTRAINT "CK_SellerServices_Notice" CHECK ("MinimumNoticeMinutes" >= 0 AND "MaximumAdvanceDays" > 0 AND "CancellationWindowMinutes" >= 0)
);
CREATE INDEX "IX_SellerServices_SellerStatus" ON "SellerServices"("SellerId","Status") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_SellerServices_StoreStatus" ON "SellerServices"("StoreId","Status") WHERE "StoreId" IS NOT NULL AND "DeletedAt" IS NULL;
CREATE INDEX "IX_SellerServices_NameTrgm" ON "SellerServices" USING GIN ("ServiceName" gin_trgm_ops);
CREATE INDEX "IX_SellerServices_CategoryLookup" ON "SellerServices"("ServiceDefinitionId","Status");

CREATE TABLE "ServiceVariants" (
 "ServiceVariantId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerServiceId" UUID NOT NULL,
 "VariantName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "DurationMinutes" INTEGER,
 "Price" NUMERIC(12,2) NOT NULL,
 "Capacity" INTEGER NOT NULL DEFAULT 1,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ServiceVariants_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE,
 CONSTRAINT "CK_ServiceVariants_Price" CHECK ("Price" >= 0),
 CONSTRAINT "CK_ServiceVariants_Duration" CHECK ("DurationMinutes" IS NULL OR "DurationMinutes" > 0),
 CONSTRAINT "CK_ServiceVariants_Capacity" CHECK ("Capacity" > 0),
 CONSTRAINT "UQ_ServiceVariants_Name" UNIQUE ("SellerServiceId","VariantName")
);
CREATE INDEX "IX_ServiceVariants_ServiceActive" ON "ServiceVariants"("SellerServiceId","IsActive");

CREATE TABLE "ServiceAddOns" (
 "ServiceAddOnId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerServiceId" UUID NOT NULL,
 "AddOnName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "AdditionalPrice" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "AdditionalMinutes" INTEGER NOT NULL DEFAULT 0,
 "IsRequired" BOOLEAN NOT NULL DEFAULT FALSE,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ServiceAddOns_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE,
 CONSTRAINT "CK_ServiceAddOns_Values" CHECK ("AdditionalPrice" >= 0 AND "AdditionalMinutes" >= 0)
);
CREATE INDEX "IX_ServiceAddOns_ServiceActive" ON "ServiceAddOns"("SellerServiceId","IsActive");

CREATE TABLE "ServiceStaff" (
 "SellerServiceId" UUID NOT NULL,
 "StaffMemberId" UUID NOT NULL,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("SellerServiceId","StaffMemberId"),
 CONSTRAINT "FK_ServiceStaff_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE,
 CONSTRAINT "FK_ServiceStaff_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE CASCADE
);
CREATE INDEX "IX_ServiceStaff_Staff" ON "ServiceStaff"("StaffMemberId","SellerServiceId");

CREATE TABLE "ServiceResources" (
 "SellerServiceId" UUID NOT NULL,
 "ResourceId" UUID NOT NULL,
 "QuantityRequired" INTEGER NOT NULL DEFAULT 1,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 PRIMARY KEY ("SellerServiceId","ResourceId"),
 CONSTRAINT "FK_ServiceResources_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE,
 CONSTRAINT "FK_ServiceResources_Resource" FOREIGN KEY ("ResourceId") REFERENCES "Resources"("ResourceId") ON DELETE CASCADE,
 CONSTRAINT "CK_ServiceResources_Quantity" CHECK ("QuantityRequired" > 0)
);

-- ============================================================================
-- BOOKINGS, ITEMS, CANCELLATIONS, WAITLIST, FORMS
-- ============================================================================
CREATE TABLE "Bookings" (
 "BookingId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingNumber" BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "Status" "BookingStatus" NOT NULL DEFAULT 'PendingApproval',
 "BookingSource" "BookingSource" NOT NULL DEFAULT 'MarketplaceWeb',
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "SubtotalAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "DiscountAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TaxAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TipAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TotalAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "DepositRequired" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "CustomerNote" TEXT,
 "InternalNote" TEXT,
 "CustomerTimeZone" VARCHAR(64),
 "ConfirmedAt" TIMESTAMPTZ,
 "CancelledAt" TIMESTAMPTZ,
 "CompletedAt" TIMESTAMPTZ,
 "ExpiresAt" TIMESTAMPTZ,
 "IdempotencyKey" VARCHAR(200),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 CONSTRAINT "FK_Bookings_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Bookings_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Bookings_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "CK_Bookings_Amounts" CHECK ("SubtotalAmount" >= 0 AND "DiscountAmount" >= 0 AND "TaxAmount" >= 0 AND "TipAmount" >= 0 AND "TotalAmount" >= 0 AND "DepositRequired" >= 0),
 CONSTRAINT "UQ_Bookings_CustomerIdempotency" UNIQUE ("CustomerUserId","IdempotencyKey")
);
CREATE INDEX "IX_Bookings_CustomerStatusStart" ON "Bookings"("CustomerUserId","Status","CreatedAt" DESC);
CREATE INDEX "IX_Bookings_SellerStatusCreated" ON "Bookings"("SellerId","Status","CreatedAt" DESC);
CREATE INDEX "IX_Bookings_StoreStatus" ON "Bookings"("StoreId","Status") WHERE "StoreId" IS NOT NULL;
CREATE INDEX "IX_Bookings_ExpiresAt" ON "Bookings"("ExpiresAt") WHERE "Status" IN ('PendingPayment','PendingApproval');
CREATE INDEX "IX_Bookings_CreatedAt" ON "Bookings"("CreatedAt" DESC);

CREATE TABLE "BookingItems" (
 "BookingItemId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingId" UUID NOT NULL,
 "SellerServiceId" UUID NOT NULL,
 "ServiceVariantId" UUID,
 "AssignedStaffMemberId" UUID,
 "Status" "BookingItemStatus" NOT NULL DEFAULT 'Pending',
 "ItemNameSnapshot" VARCHAR(200) NOT NULL,
 "VariantNameSnapshot" VARCHAR(160),
 "StartsAt" TIMESTAMPTZ NOT NULL,
 "EndsAt" TIMESTAMPTZ NOT NULL,
 "ReservedStartsAt" TIMESTAMPTZ NOT NULL,
 "ReservedEndsAt" TIMESTAMPTZ NOT NULL,
 "Quantity" INTEGER NOT NULL DEFAULT 1,
 "UnitPrice" NUMERIC(12,2) NOT NULL,
 "DiscountAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TaxAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "LineTotal" NUMERIC(12,2) NOT NULL,
 "CustomerNote" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_BookingItems_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE CASCADE,
 CONSTRAINT "FK_BookingItems_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE RESTRICT,
 CONSTRAINT "FK_BookingItems_Variant" FOREIGN KEY ("ServiceVariantId") REFERENCES "ServiceVariants"("ServiceVariantId") ON DELETE SET NULL,
 CONSTRAINT "FK_BookingItems_Staff" FOREIGN KEY ("AssignedStaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE SET NULL,
 CONSTRAINT "CK_BookingItems_Interval" CHECK ("StartsAt" < "EndsAt" AND "ReservedStartsAt" < "ReservedEndsAt" AND "ReservedStartsAt" <= "StartsAt" AND "ReservedEndsAt" >= "EndsAt"),
 CONSTRAINT "CK_BookingItems_Amounts" CHECK ("Quantity" > 0 AND "UnitPrice" >= 0 AND "DiscountAmount" >= 0 AND "TaxAmount" >= 0 AND "LineTotal" >= 0)
);
CREATE INDEX "IX_BookingItems_Booking" ON "BookingItems"("BookingId");
CREATE INDEX "IX_BookingItems_ServiceInterval" ON "BookingItems"("SellerServiceId","StartsAt","EndsAt");
CREATE INDEX "IX_BookingItems_StaffInterval" ON "BookingItems"("AssignedStaffMemberId","ReservedStartsAt","ReservedEndsAt") WHERE "AssignedStaffMemberId" IS NOT NULL;
CREATE INDEX "IX_BookingItems_Interval" ON "BookingItems" USING GIST (tstzrange("ReservedStartsAt","ReservedEndsAt",'[)'));
CREATE INDEX "IX_BookingItems_ActiveStaff" ON "BookingItems"("AssignedStaffMemberId","StartsAt") WHERE "Status" IN ('Pending','Confirmed','InProgress');

CREATE TABLE "BookingItemResources" (
 "BookingItemResourceId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingItemId" UUID NOT NULL,
 "ResourceId" UUID NOT NULL,
 "Quantity" INTEGER NOT NULL DEFAULT 1,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_BookingItemResources_Item" FOREIGN KEY ("BookingItemId") REFERENCES "BookingItems"("BookingItemId") ON DELETE CASCADE,
 CONSTRAINT "FK_BookingItemResources_Resource" FOREIGN KEY ("ResourceId") REFERENCES "Resources"("ResourceId") ON DELETE RESTRICT,
 CONSTRAINT "CK_BookingItemResources_Quantity" CHECK ("Quantity" > 0),
 CONSTRAINT "UQ_BookingItemResources_ItemResource" UNIQUE ("BookingItemId","ResourceId")
);
CREATE INDEX "IX_BookingItemResources_Resource" ON "BookingItemResources"("ResourceId","BookingItemId");

CREATE TABLE "BookingStatusHistory" (
 "BookingStatusHistoryId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingId" UUID NOT NULL,
 "OldStatus" "BookingStatus",
 "NewStatus" "BookingStatus" NOT NULL,
 "ChangedByUserId" UUID,
 "Reason" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_BookingStatusHistory_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE CASCADE,
 CONSTRAINT "FK_BookingStatusHistory_User" FOREIGN KEY ("ChangedByUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_BookingStatusHistory_BookingDate" ON "BookingStatusHistory"("BookingId","CreatedAt" DESC);

CREATE TABLE "BookingCancellations" (
 "BookingCancellationId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingId" UUID NOT NULL UNIQUE,
 "CancelledByType" "CancellationActorType" NOT NULL,
 "CancelledByUserId" UUID,
 "ReasonCode" VARCHAR(80),
 "ReasonText" TEXT,
 "CancellationFeeAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_BookingCancellations_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE RESTRICT,
 CONSTRAINT "FK_BookingCancellations_User" FOREIGN KEY ("CancelledByUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "CK_BookingCancellations_Fee" CHECK ("CancellationFeeAmount" >= 0)
);

CREATE TABLE "WaitlistEntries" (
 "WaitlistEntryId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "SellerServiceId" UUID NOT NULL,
 "PreferredStaffMemberId" UUID,
 "EarliestStartsAt" TIMESTAMPTZ NOT NULL,
 "LatestStartsAt" TIMESTAMPTZ NOT NULL,
 "Status" "WaitlistStatus" NOT NULL DEFAULT 'Waiting',
 "OfferExpiresAt" TIMESTAMPTZ,
 "BookedBookingId" UUID,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_WaitlistEntries_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "FK_WaitlistEntries_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_WaitlistEntries_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "FK_WaitlistEntries_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE,
 CONSTRAINT "FK_WaitlistEntries_Staff" FOREIGN KEY ("PreferredStaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE SET NULL,
 CONSTRAINT "FK_WaitlistEntries_Booking" FOREIGN KEY ("BookedBookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "CK_WaitlistEntries_Window" CHECK ("EarliestStartsAt" <= "LatestStartsAt")
);
CREATE INDEX "IX_WaitlistEntries_ServiceStatusWindow" ON "WaitlistEntries"("SellerServiceId","Status","EarliestStartsAt","LatestStartsAt");
CREATE INDEX "IX_WaitlistEntries_Customer" ON "WaitlistEntries"("CustomerUserId","Status");

CREATE TABLE "CustomForms" (
 "CustomFormId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "FormName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "Status" "FormStatus" NOT NULL DEFAULT 'Draft',
 "RequiredForBooking" BOOLEAN NOT NULL DEFAULT FALSE,
 "VersionNumber" INTEGER NOT NULL DEFAULT 1,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_CustomForms_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_CustomForms_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE
);
CREATE INDEX "IX_CustomForms_SellerStatus" ON "CustomForms"("SellerId","Status");

CREATE TABLE "CustomFormFields" (
 "CustomFormFieldId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CustomFormId" UUID NOT NULL,
 "FieldKey" VARCHAR(100) NOT NULL,
 "FieldLabel" VARCHAR(200) NOT NULL,
 "FieldType" VARCHAR(40) NOT NULL,
 "OptionsJson" JSONB NOT NULL DEFAULT '[]'::jsonb,
 "ValidationJson" JSONB NOT NULL DEFAULT '{}'::jsonb,
 "SortOrder" INTEGER NOT NULL DEFAULT 0,
 "IsRequired" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_CustomFormFields_Form" FOREIGN KEY ("CustomFormId") REFERENCES "CustomForms"("CustomFormId") ON DELETE CASCADE,
 CONSTRAINT "UQ_CustomFormFields_Key" UNIQUE ("CustomFormId","FieldKey")
);
CREATE INDEX "IX_CustomFormFields_FormOrder" ON "CustomFormFields"("CustomFormId","SortOrder");

CREATE TABLE "CustomFormResponses" (
 "CustomFormResponseId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CustomFormId" UUID NOT NULL,
 "CustomerUserId" UUID NOT NULL,
 "BookingId" UUID,
 "Status" "FormResponseStatus" NOT NULL DEFAULT 'InProgress',
 "AnswersJson" JSONB NOT NULL DEFAULT '{}'::jsonb,
 "SubmittedAt" TIMESTAMPTZ,
 "ReviewedAt" TIMESTAMPTZ,
 "ReviewedByUserId" UUID,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_CustomFormResponses_Form" FOREIGN KEY ("CustomFormId") REFERENCES "CustomForms"("CustomFormId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomFormResponses_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomFormResponses_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "FK_CustomFormResponses_Reviewer" FOREIGN KEY ("ReviewedByUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_CustomFormResponses_FormCustomer" ON "CustomFormResponses"("CustomFormId","CustomerUserId");
CREATE INDEX "IX_CustomFormResponses_Booking" ON "CustomFormResponses"("BookingId") WHERE "BookingId" IS NOT NULL;

-- ============================================================================
-- ORDERS, PRODUCTS, INVENTORY, PAYMENTS, REFUNDS, PAYOUTS, COMMISSIONS
-- ============================================================================
CREATE TABLE "Orders" (
 "OrderId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "OrderNumber" BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "BookingId" UUID,
 "Status" "OrderStatus" NOT NULL DEFAULT 'Draft',
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "SubtotalAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "DiscountAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TaxAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TotalAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "Notes" TEXT,
 "PlacedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Orders_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Orders_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Orders_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "FK_Orders_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "CK_Orders_Amounts" CHECK ("SubtotalAmount" >= 0 AND "DiscountAmount" >= 0 AND "TaxAmount" >= 0 AND "TotalAmount" >= 0)
);
CREATE INDEX "IX_Orders_CustomerDate" ON "Orders"("CustomerUserId","CreatedAt" DESC);
CREATE INDEX "IX_Orders_SellerStatusDate" ON "Orders"("SellerId","Status","CreatedAt" DESC);
CREATE INDEX "IX_Orders_Booking" ON "Orders"("BookingId") WHERE "BookingId" IS NOT NULL;

CREATE TABLE "Products" (
 "ProductId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "Sku" VARCHAR(100),
 "ProductName" VARCHAR(200) NOT NULL,
 "Description" TEXT,
 "Price" NUMERIC(12,2) NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "Status" "ProductStatus" NOT NULL DEFAULT 'Draft',
 "TrackInventory" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "DeletedAt" TIMESTAMPTZ,
 CONSTRAINT "FK_Products_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_Products_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "CK_Products_Price" CHECK ("Price" >= 0),
 CONSTRAINT "UQ_Products_SellerSku" UNIQUE ("SellerId","Sku")
);
CREATE INDEX "IX_Products_SellerStatus" ON "Products"("SellerId","Status") WHERE "DeletedAt" IS NULL;
CREATE INDEX "IX_Products_NameTrgm" ON "Products" USING GIN ("ProductName" gin_trgm_ops);

CREATE TABLE "InventoryBalances" (
 "InventoryBalanceId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ProductId" UUID NOT NULL,
 "StoreId" UUID,
 "QuantityOnHand" NUMERIC(14,3) NOT NULL DEFAULT 0,
 "ReorderLevel" NUMERIC(14,3) NOT NULL DEFAULT 0,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_InventoryBalances_Product" FOREIGN KEY ("ProductId") REFERENCES "Products"("ProductId") ON DELETE CASCADE,
 CONSTRAINT "FK_InventoryBalances_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "CK_InventoryBalances_Values" CHECK ("QuantityOnHand" >= 0 AND "ReorderLevel" >= 0),
 CONSTRAINT "UQ_InventoryBalances_ProductStore" UNIQUE ("ProductId","StoreId")
);
CREATE INDEX "IX_InventoryBalances_Store" ON "InventoryBalances"("StoreId");

CREATE TABLE "InventoryMovements" (
 "InventoryMovementId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ProductId" UUID NOT NULL,
 "StoreId" UUID,
 "MovementType" "InventoryMovementType" NOT NULL,
 "QuantityChange" NUMERIC(14,3) NOT NULL,
 "ReferenceType" VARCHAR(80),
 "ReferenceId" UUID,
 "Notes" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_InventoryMovements_Product" FOREIGN KEY ("ProductId") REFERENCES "Products"("ProductId") ON DELETE RESTRICT,
 CONSTRAINT "FK_InventoryMovements_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE SET NULL,
 CONSTRAINT "CK_InventoryMovements_Quantity" CHECK ("QuantityChange" <> 0)
);
CREATE INDEX "IX_InventoryMovements_ProductDate" ON "InventoryMovements"("ProductId","CreatedAt" DESC);
CREATE INDEX "IX_InventoryMovements_Reference" ON "InventoryMovements"("ReferenceType","ReferenceId") WHERE "ReferenceId" IS NOT NULL;

CREATE TABLE "OrderItems" (
 "OrderItemId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "OrderId" UUID NOT NULL,
 "ItemType" "OrderItemType" NOT NULL,
 "ProductId" UUID,
 "SellerServiceId" UUID,
 "DescriptionSnapshot" VARCHAR(250) NOT NULL,
 "Quantity" NUMERIC(12,3) NOT NULL DEFAULT 1,
 "UnitPrice" NUMERIC(12,2) NOT NULL,
 "DiscountAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "TaxAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "LineTotal" NUMERIC(12,2) NOT NULL,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_OrderItems_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE CASCADE,
 CONSTRAINT "FK_OrderItems_Product" FOREIGN KEY ("ProductId") REFERENCES "Products"("ProductId") ON DELETE SET NULL,
 CONSTRAINT "FK_OrderItems_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE SET NULL,
 CONSTRAINT "CK_OrderItems_Amounts" CHECK ("Quantity" > 0 AND "UnitPrice" >= 0 AND "DiscountAmount" >= 0 AND "TaxAmount" >= 0 AND "LineTotal" >= 0)
);
CREATE INDEX "IX_OrderItems_Order" ON "OrderItems"("OrderId");
CREATE INDEX "IX_OrderItems_Product" ON "OrderItems"("ProductId") WHERE "ProductId" IS NOT NULL;

CREATE TABLE "Payments" (
 "PaymentId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "BookingId" UUID,
 "OrderId" UUID,
 "Purpose" "PaymentPurpose" NOT NULL,
 "MethodType" "PaymentMethodType",
 "Status" "PaymentStatus" NOT NULL DEFAULT 'Pending',
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "Amount" NUMERIC(12,2) NOT NULL,
 "AmountCaptured" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "AmountRefunded" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "PaymentProvider" VARCHAR(80),
 "ProviderPaymentReference" VARCHAR(250),
 "ProviderCustomerReference" VARCHAR(250),
 "IdempotencyKey" VARCHAR(200),
 "FailureCode" VARCHAR(100),
 "FailureMessage" TEXT,
 "AuthorizedAt" TIMESTAMPTZ,
 "CapturedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Payments_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Payments_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Payments_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "FK_Payments_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE SET NULL,
 CONSTRAINT "CK_Payments_Amounts" CHECK ("Amount" >= 0 AND "AmountCaptured" >= 0 AND "AmountRefunded" >= 0 AND "AmountRefunded" <= "AmountCaptured"),
 CONSTRAINT "CK_Payments_Parent" CHECK ("BookingId" IS NOT NULL OR "OrderId" IS NOT NULL),
 CONSTRAINT "UQ_Payments_ProviderReference" UNIQUE ("PaymentProvider","ProviderPaymentReference"),
 CONSTRAINT "UQ_Payments_Idempotency" UNIQUE ("CustomerUserId","IdempotencyKey")
);
CREATE INDEX "IX_Payments_Booking" ON "Payments"("BookingId","Status") WHERE "BookingId" IS NOT NULL;
CREATE INDEX "IX_Payments_Order" ON "Payments"("OrderId","Status") WHERE "OrderId" IS NOT NULL;
CREATE INDEX "IX_Payments_SellerDate" ON "Payments"("SellerId","CreatedAt" DESC);
CREATE INDEX "IX_Payments_StatusDate" ON "Payments"("Status","CreatedAt");

CREATE TABLE "Refunds" (
 "RefundId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "PaymentId" UUID NOT NULL,
 "Amount" NUMERIC(12,2) NOT NULL,
 "Reason" TEXT,
 "Status" "RefundStatus" NOT NULL DEFAULT 'Pending',
 "ProviderRefundReference" VARCHAR(250),
 "FailureMessage" TEXT,
 "ProcessedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Refunds_Payment" FOREIGN KEY ("PaymentId") REFERENCES "Payments"("PaymentId") ON DELETE RESTRICT,
 CONSTRAINT "CK_Refunds_Amount" CHECK ("Amount" > 0),
 CONSTRAINT "UQ_Refunds_ProviderReference" UNIQUE ("ProviderRefundReference")
);
CREATE INDEX "IX_Refunds_PaymentStatus" ON "Refunds"("PaymentId","Status");

CREATE TABLE "Payouts" (
 "PayoutId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "GrossAmount" NUMERIC(12,2) NOT NULL,
 "FeeAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "AdjustmentAmount" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "NetAmount" NUMERIC(12,2) NOT NULL,
 "Status" "PayoutStatus" NOT NULL DEFAULT 'Pending',
 "PaymentProvider" VARCHAR(80),
 "ProviderPayoutReference" VARCHAR(250),
 "ScheduledAt" TIMESTAMPTZ,
 "PaidAt" TIMESTAMPTZ,
 "FailureMessage" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Payouts_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "CK_Payouts_Amounts" CHECK ("GrossAmount" >= 0 AND "FeeAmount" >= 0 AND "NetAmount" >= 0),
 CONSTRAINT "UQ_Payouts_ProviderReference" UNIQUE ("PaymentProvider","ProviderPayoutReference")
);
CREATE INDEX "IX_Payouts_SellerStatusDate" ON "Payouts"("SellerId","Status","CreatedAt" DESC);

CREATE TABLE "PayoutItems" (
 "PayoutItemId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "PayoutId" UUID NOT NULL,
 "PaymentId" UUID,
 "Amount" NUMERIC(12,2) NOT NULL,
 "Description" VARCHAR(250),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_PayoutItems_Payout" FOREIGN KEY ("PayoutId") REFERENCES "Payouts"("PayoutId") ON DELETE CASCADE,
 CONSTRAINT "FK_PayoutItems_Payment" FOREIGN KEY ("PaymentId") REFERENCES "Payments"("PaymentId") ON DELETE SET NULL,
 CONSTRAINT "CK_PayoutItems_Amount" CHECK ("Amount" >= 0)
);
CREATE INDEX "IX_PayoutItems_Payout" ON "PayoutItems"("PayoutId");
CREATE INDEX "IX_PayoutItems_Payment" ON "PayoutItems"("PaymentId") WHERE "PaymentId" IS NOT NULL;

CREATE TABLE "StaffCommissions" (
 "StaffCommissionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StaffMemberId" UUID NOT NULL,
 "BookingItemId" UUID,
 "OrderItemId" UUID,
 "CommissionRate" NUMERIC(5,2),
 "CommissionAmount" NUMERIC(12,2) NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_StaffCommissions_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_StaffCommissions_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE RESTRICT,
 CONSTRAINT "FK_StaffCommissions_BookingItem" FOREIGN KEY ("BookingItemId") REFERENCES "BookingItems"("BookingItemId") ON DELETE SET NULL,
 CONSTRAINT "FK_StaffCommissions_OrderItem" FOREIGN KEY ("OrderItemId") REFERENCES "OrderItems"("OrderItemId") ON DELETE SET NULL,
 CONSTRAINT "CK_StaffCommissions_Amount" CHECK ("CommissionAmount" >= 0 AND ("CommissionRate" IS NULL OR "CommissionRate" BETWEEN 0 AND 100)),
 CONSTRAINT "CK_StaffCommissions_Source" CHECK ("BookingItemId" IS NOT NULL OR "OrderItemId" IS NOT NULL)
);
CREATE INDEX "IX_StaffCommissions_StaffDate" ON "StaffCommissions"("StaffMemberId","CreatedAt" DESC);
CREATE INDEX "IX_StaffCommissions_SellerDate" ON "StaffCommissions"("SellerId","CreatedAt" DESC);

-- ============================================================================
-- PROMOTIONS, GIFT CARDS, PACKAGES, MEMBERSHIPS, LOYALTY, SUBSCRIPTIONS
-- ============================================================================
CREATE TABLE "Promotions" (
 "PromotionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "StoreId" UUID,
 "PromotionCode" CITEXT,
 "PromotionName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "DiscountType" "DiscountType" NOT NULL,
 "DiscountValue" NUMERIC(12,2) NOT NULL,
 "MinimumSpend" NUMERIC(12,2) NOT NULL DEFAULT 0,
 "MaximumDiscount" NUMERIC(12,2),
 "StartsAt" TIMESTAMPTZ,
 "EndsAt" TIMESTAMPTZ,
 "UsageLimit" INTEGER,
 "PerCustomerLimit" INTEGER,
 "Status" "PromotionStatus" NOT NULL DEFAULT 'Draft',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Promotions_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_Promotions_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE,
 CONSTRAINT "CK_Promotions_Value" CHECK ("DiscountValue" >= 0 AND "MinimumSpend" >= 0 AND ("MaximumDiscount" IS NULL OR "MaximumDiscount" >= 0)),
 CONSTRAINT "CK_Promotions_Percent" CHECK ("DiscountType" <> 'Percentage' OR "DiscountValue" <= 100),
 CONSTRAINT "CK_Promotions_Dates" CHECK ("EndsAt" IS NULL OR "StartsAt" IS NULL OR "EndsAt" > "StartsAt")
);
CREATE INDEX "IX_Promotions_SellerStatusDates" ON "Promotions"("SellerId","Status","StartsAt","EndsAt");
CREATE UNIQUE INDEX "UX_Promotions_SellerCode" ON "Promotions"("SellerId","PromotionCode") WHERE "PromotionCode" IS NOT NULL;

CREATE TABLE "PromotionServices" (
 "PromotionId" UUID NOT NULL,
 "SellerServiceId" UUID NOT NULL,
 PRIMARY KEY ("PromotionId","SellerServiceId"),
 CONSTRAINT "FK_PromotionServices_Promotion" FOREIGN KEY ("PromotionId") REFERENCES "Promotions"("PromotionId") ON DELETE CASCADE,
 CONSTRAINT "FK_PromotionServices_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE CASCADE
);
CREATE INDEX "IX_PromotionServices_Service" ON "PromotionServices"("SellerServiceId");

CREATE TABLE "PromotionRedemptions" (
 "PromotionRedemptionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "PromotionId" UUID NOT NULL,
 "CustomerUserId" UUID NOT NULL,
 "BookingId" UUID,
 "OrderId" UUID,
 "DiscountAmount" NUMERIC(12,2) NOT NULL,
 "RedeemedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_PromotionRedemptions_Promotion" FOREIGN KEY ("PromotionId") REFERENCES "Promotions"("PromotionId") ON DELETE RESTRICT,
 CONSTRAINT "FK_PromotionRedemptions_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_PromotionRedemptions_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "FK_PromotionRedemptions_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE SET NULL,
 CONSTRAINT "CK_PromotionRedemptions_Amount" CHECK ("DiscountAmount" >= 0),
 CONSTRAINT "CK_PromotionRedemptions_Source" CHECK ("BookingId" IS NOT NULL OR "OrderId" IS NOT NULL)
);
CREATE INDEX "IX_PromotionRedemptions_PromotionDate" ON "PromotionRedemptions"("PromotionId","RedeemedAt" DESC);
CREATE INDEX "IX_PromotionRedemptions_Customer" ON "PromotionRedemptions"("CustomerUserId","RedeemedAt" DESC);

CREATE TABLE "GiftCards" (
 "GiftCardId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "CodeHash" TEXT NOT NULL UNIQUE,
 "DisplayCodeLast4" CHAR(4),
 "InitialBalance" NUMERIC(12,2) NOT NULL,
 "CurrentBalance" NUMERIC(12,2) NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "PurchaserUserId" UUID,
 "RecipientEmail" CITEXT,
 "RecipientName" VARCHAR(160),
 "Status" "GiftCardStatus" NOT NULL DEFAULT 'Pending',
 "ExpiresAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_GiftCards_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "FK_GiftCards_Purchaser" FOREIGN KEY ("PurchaserUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "CK_GiftCards_Balance" CHECK ("InitialBalance" >= 0 AND "CurrentBalance" >= 0 AND "CurrentBalance" <= "InitialBalance")
);
CREATE INDEX "IX_GiftCards_SellerStatus" ON "GiftCards"("SellerId","Status");
CREATE INDEX "IX_GiftCards_Recipient" ON "GiftCards"("RecipientEmail") WHERE "RecipientEmail" IS NOT NULL;

CREATE TABLE "GiftCardTransactions" (
 "GiftCardTransactionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "GiftCardId" UUID NOT NULL,
 "PaymentId" UUID,
 "OrderId" UUID,
 "AmountChange" NUMERIC(12,2) NOT NULL,
 "TransactionType" VARCHAR(40) NOT NULL,
 "Notes" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_GiftCardTransactions_GiftCard" FOREIGN KEY ("GiftCardId") REFERENCES "GiftCards"("GiftCardId") ON DELETE RESTRICT,
 CONSTRAINT "FK_GiftCardTransactions_Payment" FOREIGN KEY ("PaymentId") REFERENCES "Payments"("PaymentId") ON DELETE SET NULL,
 CONSTRAINT "FK_GiftCardTransactions_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE SET NULL,
 CONSTRAINT "CK_GiftCardTransactions_Change" CHECK ("AmountChange" <> 0)
);
CREATE INDEX "IX_GiftCardTransactions_CardDate" ON "GiftCardTransactions"("GiftCardId","CreatedAt" DESC);

CREATE TABLE "ServicePackages" (
 "ServicePackageId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "PackageName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "Price" NUMERIC(12,2) NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "ValidityDays" INTEGER,
 "Status" "PackageStatus" NOT NULL DEFAULT 'Draft',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ServicePackages_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "CK_ServicePackages_Price" CHECK ("Price" >= 0),
 CONSTRAINT "CK_ServicePackages_Validity" CHECK ("ValidityDays" IS NULL OR "ValidityDays" > 0)
);
CREATE INDEX "IX_ServicePackages_SellerStatus" ON "ServicePackages"("SellerId","Status");

CREATE TABLE "ServicePackageItems" (
 "ServicePackageItemId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ServicePackageId" UUID NOT NULL,
 "SellerServiceId" UUID NOT NULL,
 "IncludedQuantity" INTEGER NOT NULL DEFAULT 1,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_ServicePackageItems_Package" FOREIGN KEY ("ServicePackageId") REFERENCES "ServicePackages"("ServicePackageId") ON DELETE CASCADE,
 CONSTRAINT "FK_ServicePackageItems_Service" FOREIGN KEY ("SellerServiceId") REFERENCES "SellerServices"("SellerServiceId") ON DELETE RESTRICT,
 CONSTRAINT "CK_ServicePackageItems_Quantity" CHECK ("IncludedQuantity" > 0),
 CONSTRAINT "UQ_ServicePackageItems_Service" UNIQUE ("ServicePackageId","SellerServiceId")
);
CREATE INDEX "IX_ServicePackageItems_Service" ON "ServicePackageItems"("SellerServiceId");

CREATE TABLE "CustomerPackages" (
 "CustomerPackageId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ServicePackageId" UUID NOT NULL,
 "CustomerUserId" UUID NOT NULL,
 "OrderId" UUID,
 "PurchasedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "ExpiresAt" TIMESTAMPTZ,
 "Status" "PackageStatus" NOT NULL DEFAULT 'Active',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_CustomerPackages_Package" FOREIGN KEY ("ServicePackageId") REFERENCES "ServicePackages"("ServicePackageId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomerPackages_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomerPackages_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE SET NULL
);
CREATE INDEX "IX_CustomerPackages_CustomerStatus" ON "CustomerPackages"("CustomerUserId","Status","ExpiresAt");

CREATE TABLE "MembershipPlans" (
 "MembershipPlanId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "PlanName" VARCHAR(160) NOT NULL,
 "Description" TEXT,
 "Price" NUMERIC(12,2) NOT NULL,
 "CurrencyCode" CHAR(3) NOT NULL DEFAULT 'INR',
 "BillingInterval" VARCHAR(20) NOT NULL DEFAULT 'Month',
 "IncludedBenefits" JSONB NOT NULL DEFAULT '{}'::jsonb,
 "Status" "MembershipPlanStatus" NOT NULL DEFAULT 'Draft',
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_MembershipPlans_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "CK_MembershipPlans_Price" CHECK ("Price" >= 0),
 CONSTRAINT "CK_MembershipPlans_Interval" CHECK ("BillingInterval" IN ('Week','Month','Quarter','Year'))
);
CREATE INDEX "IX_MembershipPlans_SellerStatus" ON "MembershipPlans"("SellerId","Status");

CREATE TABLE "CustomerMemberships" (
 "CustomerMembershipId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "MembershipPlanId" UUID NOT NULL,
 "CustomerUserId" UUID NOT NULL,
 "OrderId" UUID,
 "Status" "SubscriptionStatus" NOT NULL DEFAULT 'Active',
 "StartsAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CurrentPeriodEndsAt" TIMESTAMPTZ,
 "CancelledAt" TIMESTAMPTZ,
 "ExternalSubscriptionReference" VARCHAR(250),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_CustomerMemberships_Plan" FOREIGN KEY ("MembershipPlanId") REFERENCES "MembershipPlans"("MembershipPlanId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomerMemberships_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_CustomerMemberships_Order" FOREIGN KEY ("OrderId") REFERENCES "Orders"("OrderId") ON DELETE SET NULL
);
CREATE INDEX "IX_CustomerMemberships_CustomerStatus" ON "CustomerMemberships"("CustomerUserId","Status");
CREATE INDEX "IX_CustomerMemberships_PlanStatus" ON "CustomerMemberships"("MembershipPlanId","Status");

CREATE TABLE "LoyaltyPrograms" (
 "LoyaltyProgramId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "ProgramName" VARCHAR(160) NOT NULL,
 "StampsRequired" INTEGER NOT NULL,
 "RewardDescription" VARCHAR(250) NOT NULL,
 "IsActive" BOOLEAN NOT NULL DEFAULT TRUE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_LoyaltyPrograms_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "CK_LoyaltyPrograms_Stamps" CHECK ("StampsRequired" > 0)
);
CREATE INDEX "IX_LoyaltyPrograms_SellerActive" ON "LoyaltyPrograms"("SellerId","IsActive");

CREATE TABLE "CustomerLoyaltyAccounts" (
 "CustomerLoyaltyAccountId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "LoyaltyProgramId" UUID NOT NULL,
 "CustomerUserId" UUID NOT NULL,
 "CurrentStamps" INTEGER NOT NULL DEFAULT 0,
 "RewardsEarned" INTEGER NOT NULL DEFAULT 0,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_CustomerLoyaltyAccounts_Program" FOREIGN KEY ("LoyaltyProgramId") REFERENCES "LoyaltyPrograms"("LoyaltyProgramId") ON DELETE CASCADE,
 CONSTRAINT "FK_CustomerLoyaltyAccounts_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "CK_CustomerLoyaltyAccounts_Values" CHECK ("CurrentStamps" >= 0 AND "RewardsEarned" >= 0),
 CONSTRAINT "UQ_CustomerLoyaltyAccounts_ProgramCustomer" UNIQUE ("LoyaltyProgramId","CustomerUserId")
);
CREATE INDEX "IX_CustomerLoyaltyAccounts_Customer" ON "CustomerLoyaltyAccounts"("CustomerUserId");

CREATE TABLE "LoyaltyTransactions" (
 "LoyaltyTransactionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "CustomerLoyaltyAccountId" UUID NOT NULL,
 "BookingId" UUID,
 "StampChange" INTEGER NOT NULL,
 "RewardChange" INTEGER NOT NULL DEFAULT 0,
 "Description" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_LoyaltyTransactions_Account" FOREIGN KEY ("CustomerLoyaltyAccountId") REFERENCES "CustomerLoyaltyAccounts"("CustomerLoyaltyAccountId") ON DELETE RESTRICT,
 CONSTRAINT "FK_LoyaltyTransactions_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL
);
CREATE INDEX "IX_LoyaltyTransactions_AccountDate" ON "LoyaltyTransactions"("CustomerLoyaltyAccountId","CreatedAt" DESC);

CREATE TABLE "SellerSubscriptions" (
 "SellerSubscriptionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID NOT NULL,
 "PlanCode" VARCHAR(80) NOT NULL,
 "Status" "SubscriptionStatus" NOT NULL DEFAULT 'Trialing',
 "ExternalCustomerReference" VARCHAR(250),
 "ExternalSubscriptionReference" VARCHAR(250),
 "TrialEndsAt" TIMESTAMPTZ,
 "CurrentPeriodStartsAt" TIMESTAMPTZ,
 "CurrentPeriodEndsAt" TIMESTAMPTZ,
 "CancelledAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_SellerSubscriptions_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE RESTRICT,
 CONSTRAINT "UQ_SellerSubscriptions_External" UNIQUE ("ExternalSubscriptionReference")
);
CREATE INDEX "IX_SellerSubscriptions_SellerStatus" ON "SellerSubscriptions"("SellerId","Status");
CREATE INDEX "IX_SellerSubscriptions_Renewal" ON "SellerSubscriptions"("CurrentPeriodEndsAt") WHERE "Status" IN ('Trialing','Active','PastDue');

-- ============================================================================
-- FAVORITES, REVIEWS, REPORTS, SUPPORT, NOTIFICATIONS, INTEGRATIONS, AUDIT
-- ============================================================================
CREATE TABLE "CustomerFavorites" (
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 PRIMARY KEY ("CustomerUserId","SellerId"),
 CONSTRAINT "FK_CustomerFavorites_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE CASCADE,
 CONSTRAINT "FK_CustomerFavorites_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE
);
CREATE INDEX "IX_CustomerFavorites_Seller" ON "CustomerFavorites"("SellerId","CreatedAt" DESC);

CREATE TABLE "Reviews" (
 "ReviewId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "BookingId" UUID,
 "BookingItemId" UUID,
 "CustomerUserId" UUID NOT NULL,
 "SellerId" UUID NOT NULL,
 "StaffMemberId" UUID,
 "Rating" SMALLINT NOT NULL,
 "ReviewTitle" VARCHAR(200),
 "ReviewText" TEXT,
 "Status" "ReviewStatus" NOT NULL DEFAULT 'Pending',
 "SellerResponse" TEXT,
 "SellerRespondedAt" TIMESTAMPTZ,
 "PublishedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_Reviews_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "FK_Reviews_BookingItem" FOREIGN KEY ("BookingItemId") REFERENCES "BookingItems"("BookingItemId") ON DELETE SET NULL,
 CONSTRAINT "FK_Reviews_Customer" FOREIGN KEY ("CustomerUserId") REFERENCES "Users"("UserId") ON DELETE RESTRICT,
 CONSTRAINT "FK_Reviews_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_Reviews_Staff" FOREIGN KEY ("StaffMemberId") REFERENCES "StaffMembers"("StaffMemberId") ON DELETE SET NULL,
 CONSTRAINT "CK_Reviews_Rating" CHECK ("Rating" BETWEEN 1 AND 5),
 CONSTRAINT "UQ_Reviews_CustomerBookingItem" UNIQUE ("CustomerUserId","BookingItemId")
);
CREATE INDEX "IX_Reviews_SellerStatusPublished" ON "Reviews"("SellerId","Status","PublishedAt" DESC);
CREATE INDEX "IX_Reviews_CustomerDate" ON "Reviews"("CustomerUserId","CreatedAt" DESC);
CREATE INDEX "IX_Reviews_Staff" ON "Reviews"("StaffMemberId","Status") WHERE "StaffMemberId" IS NOT NULL;

CREATE TABLE "ContentReports" (
 "ContentReportId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "ReporterUserId" UUID,
 "SellerId" UUID,
 "ReviewId" UUID,
 "ReasonCode" VARCHAR(80) NOT NULL,
 "Description" TEXT,
 "Status" "ReportStatus" NOT NULL DEFAULT 'Open',
 "AssignedToUserId" UUID,
 "ResolutionNotes" TEXT,
 "ResolvedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ContentReports_Reporter" FOREIGN KEY ("ReporterUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_ContentReports_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_ContentReports_Review" FOREIGN KEY ("ReviewId") REFERENCES "Reviews"("ReviewId") ON DELETE CASCADE,
 CONSTRAINT "FK_ContentReports_Assignee" FOREIGN KEY ("AssignedToUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_ContentReports_StatusDate" ON "ContentReports"("Status","CreatedAt");
CREATE INDEX "IX_ContentReports_Seller" ON "ContentReports"("SellerId") WHERE "SellerId" IS NOT NULL;

CREATE TABLE "SupportTickets" (
 "SupportTicketId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "TicketNumber" BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
 "CreatedByUserId" UUID,
 "SellerId" UUID,
 "BookingId" UUID,
 "Subject" VARCHAR(200) NOT NULL,
 "Description" TEXT NOT NULL,
 "Status" "SupportTicketStatus" NOT NULL DEFAULT 'Open',
 "Priority" "SupportPriority" NOT NULL DEFAULT 'Normal',
 "AssignedToUserId" UUID,
 "ResolvedAt" TIMESTAMPTZ,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_SupportTickets_Creator" FOREIGN KEY ("CreatedByUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_SupportTickets_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE SET NULL,
 CONSTRAINT "FK_SupportTickets_Booking" FOREIGN KEY ("BookingId") REFERENCES "Bookings"("BookingId") ON DELETE SET NULL,
 CONSTRAINT "FK_SupportTickets_Assignee" FOREIGN KEY ("AssignedToUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_SupportTickets_StatusPriorityDate" ON "SupportTickets"("Status","Priority","CreatedAt");
CREATE INDEX "IX_SupportTickets_CreatorDate" ON "SupportTickets"("CreatedByUserId","CreatedAt" DESC);
CREATE INDEX "IX_SupportTickets_SellerDate" ON "SupportTickets"("SellerId","CreatedAt" DESC) WHERE "SellerId" IS NOT NULL;

CREATE TABLE "SupportTicketMessages" (
 "SupportTicketMessageId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SupportTicketId" UUID NOT NULL,
 "SenderUserId" UUID,
 "MessageText" TEXT NOT NULL,
 "IsInternalNote" BOOLEAN NOT NULL DEFAULT FALSE,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_SupportTicketMessages_Ticket" FOREIGN KEY ("SupportTicketId") REFERENCES "SupportTickets"("SupportTicketId") ON DELETE CASCADE,
 CONSTRAINT "FK_SupportTicketMessages_Sender" FOREIGN KEY ("SenderUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL
);
CREATE INDEX "IX_SupportTicketMessages_TicketDate" ON "SupportTicketMessages"("SupportTicketId","CreatedAt");

CREATE TABLE "NotificationJobs" (
 "NotificationJobId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "UserId" UUID,
 "SellerId" UUID,
 "Channel" "NotificationChannel" NOT NULL,
 "TemplateCode" VARCHAR(100) NOT NULL,
 "Recipient" VARCHAR(255) NOT NULL,
 "PayloadJson" JSONB NOT NULL DEFAULT '{}'::jsonb,
 "Status" "NotificationStatus" NOT NULL DEFAULT 'Queued',
 "ScheduledAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "ProcessedAt" TIMESTAMPTZ,
 "AttemptCount" INTEGER NOT NULL DEFAULT 0,
 "NextAttemptAt" TIMESTAMPTZ,
 "LastError" TEXT,
 "IdempotencyKey" VARCHAR(200),
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_NotificationJobs_User" FOREIGN KEY ("UserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_NotificationJobs_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE SET NULL,
 CONSTRAINT "CK_NotificationJobs_Attempts" CHECK ("AttemptCount" >= 0),
 CONSTRAINT "UQ_NotificationJobs_Idempotency" UNIQUE ("IdempotencyKey")
);
CREATE INDEX "IX_NotificationJobs_Queue" ON "NotificationJobs"("Status","ScheduledAt") WHERE "Status" IN ('Queued','Failed');
CREATE INDEX "IX_NotificationJobs_UserDate" ON "NotificationJobs"("UserId","CreatedAt" DESC) WHERE "UserId" IS NOT NULL;

CREATE TABLE "NotificationDeliveries" (
 "NotificationDeliveryId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "NotificationJobId" UUID NOT NULL,
 "ProviderName" VARCHAR(80),
 "ProviderMessageReference" VARCHAR(250),
 "Status" "NotificationStatus" NOT NULL DEFAULT 'Queued',
 "AttemptNumber" INTEGER NOT NULL DEFAULT 1,
 "ResponseJson" JSONB,
 "ErrorMessage" TEXT,
 "AttemptedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_NotificationDeliveries_Job" FOREIGN KEY ("NotificationJobId") REFERENCES "NotificationJobs"("NotificationJobId") ON DELETE CASCADE,
 CONSTRAINT "CK_NotificationDeliveries_Attempt" CHECK ("AttemptNumber" > 0),
 CONSTRAINT "UQ_NotificationDeliveries_ProviderRef" UNIQUE ("ProviderName","ProviderMessageReference")
);
CREATE INDEX "IX_NotificationDeliveries_JobAttempt" ON "NotificationDeliveries"("NotificationJobId","AttemptedAt" DESC);

CREATE TABLE "OutboxEvents" (
 "OutboxEventId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "AggregateType" VARCHAR(100) NOT NULL,
 "AggregateId" UUID NOT NULL,
 "EventType" VARCHAR(150) NOT NULL,
 "PayloadJson" JSONB NOT NULL,
 "Status" "OutboxStatus" NOT NULL DEFAULT 'Pending',
 "AttemptCount" INTEGER NOT NULL DEFAULT 0,
 "AvailableAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "PublishedAt" TIMESTAMPTZ,
 "LastError" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "CK_OutboxEvents_Attempts" CHECK ("AttemptCount" >= 0)
);
CREATE INDEX "IX_OutboxEvents_Queue" ON "OutboxEvents"("Status","AvailableAt","CreatedAt") WHERE "Status" IN ('Pending','Failed');
CREATE INDEX "IX_OutboxEvents_Aggregate" ON "OutboxEvents"("AggregateType","AggregateId","CreatedAt");

CREATE TABLE "IntegrationConnections" (
 "IntegrationConnectionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "SellerId" UUID,
 "StoreId" UUID,
 "IntegrationType" VARCHAR(80) NOT NULL,
 "ExternalAccountReference" VARCHAR(250),
 "Status" "IntegrationStatus" NOT NULL DEFAULT 'Pending',
 "ConfigurationJson" JSONB NOT NULL DEFAULT '{}'::jsonb,
 "SecretReference" TEXT,
 "LastSyncedAt" TIMESTAMPTZ,
 "LastError" TEXT,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "CreatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 "UpdatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "UpdatedBy" UUID REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_IntegrationConnections_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE CASCADE,
 CONSTRAINT "FK_IntegrationConnections_Store" FOREIGN KEY ("StoreId") REFERENCES "Stores"("StoreId") ON DELETE CASCADE
);
CREATE INDEX "IX_IntegrationConnections_SellerType" ON "IntegrationConnections"("SellerId","IntegrationType","Status");
CREATE INDEX "IX_IntegrationConnections_StoreType" ON "IntegrationConnections"("StoreId","IntegrationType") WHERE "StoreId" IS NOT NULL;

CREATE TABLE "WebhookEvents" (
 "WebhookEventId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 "IntegrationConnectionId" UUID,
 "ProviderName" VARCHAR(80) NOT NULL,
 "ExternalEventId" VARCHAR(250) NOT NULL,
 "EventType" VARCHAR(150) NOT NULL,
 "PayloadJson" JSONB NOT NULL,
 "DeliveryStatus" "WebhookDeliveryStatus" NOT NULL DEFAULT 'Pending',
 "ReceivedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 "ProcessedAt" TIMESTAMPTZ,
 "AttemptCount" INTEGER NOT NULL DEFAULT 0,
 "LastError" TEXT,
 CONSTRAINT "FK_WebhookEvents_Connection" FOREIGN KEY ("IntegrationConnectionId") REFERENCES "IntegrationConnections"("IntegrationConnectionId") ON DELETE SET NULL,
 CONSTRAINT "UQ_WebhookEvents_ProviderEvent" UNIQUE ("ProviderName","ExternalEventId")
);
CREATE INDEX "IX_WebhookEvents_StatusReceived" ON "WebhookEvents"("DeliveryStatus","ReceivedAt");
CREATE INDEX "IX_WebhookEvents_TypeReceived" ON "WebhookEvents"("EventType","ReceivedAt" DESC);

CREATE TABLE "AuditLogs" (
 "AuditLogId" BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 "ActorUserId" UUID,
 "SellerId" UUID,
 "Action" "AuditAction" NOT NULL,
 "EntityName" VARCHAR(150) NOT NULL,
 "EntityId" VARCHAR(150),
 "OldValues" JSONB,
 "NewValues" JSONB,
 "IpAddress" INET,
 "UserAgent" TEXT,
 "CorrelationId" UUID,
 "CreatedAt" TIMESTAMPTZ NOT NULL DEFAULT now(),
 CONSTRAINT "FK_AuditLogs_Actor" FOREIGN KEY ("ActorUserId") REFERENCES "Users"("UserId") ON DELETE SET NULL,
 CONSTRAINT "FK_AuditLogs_Seller" FOREIGN KEY ("SellerId") REFERENCES "Sellers"("SellerId") ON DELETE SET NULL
);
CREATE INDEX "IX_AuditLogs_ActorDate" ON "AuditLogs"("ActorUserId","CreatedAt" DESC);
CREATE INDEX "IX_AuditLogs_SellerDate" ON "AuditLogs"("SellerId","CreatedAt" DESC) WHERE "SellerId" IS NOT NULL;
CREATE INDEX "IX_AuditLogs_Entity" ON "AuditLogs"("EntityName","EntityId","CreatedAt" DESC);
CREATE INDEX "IX_AuditLogs_Correlation" ON "AuditLogs"("CorrelationId") WHERE "CorrelationId" IS NOT NULL;

-- ============================================================================
-- DATABASE HELPERS AND INITIAL SYSTEM ROLES
-- ============================================================================
CREATE OR REPLACE FUNCTION "SetUpdatedAt"()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW."UpdatedAt" := now();
  RETURN NEW;
END;
$$;

-- Keep UpdatedAt consistent even if an application forgets to set it.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'Users','UserProfiles','Roles','Sellers','SellerMembers','Stores','Categories',
    'Files','StoreHours','StaffMembers','StaffSchedules','ScheduleExceptions',
    'Resources','ServiceDefinitions','SellerServices','ServiceVariants','ServiceAddOns',
    'Bookings','BookingItems','WaitlistEntries','CustomForms','CustomFormResponses',
    'Orders','Products','Payments','Refunds','Payouts','Promotions','GiftCards',
    'ServicePackages','MembershipPlans','CustomerMemberships','LoyaltyPrograms',
    'SellerSubscriptions','Reviews','ContentReports','SupportTickets','IntegrationConnections'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION "SetUpdatedAt"()',
      'TR_' || t || '_SetUpdatedAt', t
    );
  END LOOP;
END $$;

INSERT INTO "Roles" ("RoleCode","RoleName","Description","IsSystemRole")
VALUES
 ('PlatformAdmin','Platform Administrator','Full platform-level administration',TRUE),
 ('SellerOwner','Seller Owner','Owns and administers a seller account',TRUE),
 ('SellerManager','Seller Manager','Manages seller operations and staff',TRUE),
 ('SellerStaff','Seller Staff','Performs assigned operational tasks',TRUE),
 ('Customer','Customer','Books services and purchases products',TRUE)
ON CONFLICT ("RoleCode") DO NOTHING;

COMMIT;

-- ============================================================================
-- POST-INSTALLATION NOTES
-- ============================================================================
-- 1. Seed Permissions and map them to Roles in RolePermissions.
-- 2. Add authorization checks in Rust for every seller-owned record.
-- 3. Enforce cross-table ownership consistency in application logic or with
--    additional composite foreign keys (e.g., StoreId belongs to SellerId).
-- 4. Implement booking creation in one transaction and recheck availability
--    after acquiring the required locks.
-- 5. If staff/resources must never overlap, use a dedicated reservation table
--    with a partial GiST EXCLUDE constraint on (StaffMemberId WITH =,
--    tstzrange(ReservedStartsAt, ReservedEndsAt, '[)') WITH &&) for active
--    reservation states. Do not apply a naive constraint to BookingItems here
--    because status changes and capacity-based booking models need deliberate
--    handling.
-- 6. For large-scale analytics, consider reporting views/materialized views
--    and partition high-volume audit/event tables after measuring workload.
-- 7. Review enum changes through migrations; PostgreSQL enums are intentionally
--    strict, so avoid using them for values that users can configure freely.
