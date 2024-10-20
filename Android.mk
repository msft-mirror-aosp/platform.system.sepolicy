LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)

ifdef BOARD_SEPOLICY_UNION
$(warning BOARD_SEPOLICY_UNION is no longer required - all files found in BOARD_SEPOLICY_DIRS are implicitly unioned; please remove from your BoardConfig.mk or other .mk file.)
endif

# sepolicy is now divided into multiple portions:
# public - policy exported on which non-platform policy developers may write
#   additional policy.  types and attributes are versioned and included in
#   delivered non-platform policy, which is to be combined with platform policy.
# private - platform-only policy required for platform functionality but which
#  is not exported to vendor policy developers and as such may not be assumed
#  to exist.
# vendor - vendor-only policy required for vendor functionality. This policy can
#  reference the public policy but cannot reference the private policy. This
#  policy is for components which are produced from the core/non-vendor tree and
#  placed into a vendor partition.
# mapping - This contains policy statements which map the attributes
#  exposed in the public policy of previous versions to the concrete types used
#  in this policy to ensure that policy targeting attributes from public
#  policy from an older platform version continues to work.

# build process for device:
# 1) convert policies to CIL:
#    - private + public platform policy to CIL
#    - mapping file to CIL (should already be in CIL form)
#    - non-platform public policy to CIL
#    - non-platform public + private policy to CIL
# 2) attributize policy
#    - run script which takes non-platform public and non-platform combined
#      private + public policy and produces attributized and versioned
#      non-platform policy
# 3) combine policy files
#    - combine mapping, platform and non-platform policy.
#    - compile output binary policy file

PLAT_PUBLIC_POLICY := $(LOCAL_PATH)/public
PLAT_PRIVATE_POLICY := $(LOCAL_PATH)/private
PLAT_VENDOR_POLICY := $(LOCAL_PATH)/vendor
REQD_MASK_POLICY := $(LOCAL_PATH)/reqd_mask

SYSTEM_EXT_PUBLIC_POLICY := $(SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS)
SYSTEM_EXT_PRIVATE_POLICY := $(SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS)

PRODUCT_PUBLIC_POLICY := $(PRODUCT_PUBLIC_SEPOLICY_DIRS)
PRODUCT_PRIVATE_POLICY := $(PRODUCT_PRIVATE_SEPOLICY_DIRS)

ifneq (,$(SYSTEM_EXT_PUBLIC_POLICY)$(SYSTEM_EXT_PRIVATE_POLICY))
HAS_SYSTEM_EXT_SEPOLICY_DIR := true
endif

# TODO(b/119305624): Currently if the device doesn't have a product partition,
# we install product sepolicy into /system/product. We do that because bits of
# product sepolicy that's still in /system might depend on bits that have moved
# to /product. Once we finish migrating product sepolicy out of system, change
# it so that if no product partition is present, product sepolicy artifacts are
# not built and installed at all.
ifneq (,$(PRODUCT_PUBLIC_POLICY)$(PRODUCT_PRIVATE_POLICY))
HAS_PRODUCT_SEPOLICY_DIR := true
endif

ifeq ($(SELINUX_IGNORE_NEVERALLOWS),true)
ifeq ($(TARGET_BUILD_VARIANT),user)
$(error SELINUX_IGNORE_NEVERALLOWS := true cannot be used in user builds)
endif
$(warning Be careful when using the SELINUX_IGNORE_NEVERALLOWS flag. \
          It does not work in user builds and using it will \
          not stop you from failing CTS.)
endif

# BOARD_SEPOLICY_DIRS was used for vendor/odm sepolicy customization before.
# It has been replaced by BOARD_VENDOR_SEPOLICY_DIRS (mandatory) and
# BOARD_ODM_SEPOLICY_DIRS (optional). BOARD_SEPOLICY_DIRS is still allowed for
# backward compatibility, which will be merged into BOARD_VENDOR_SEPOLICY_DIRS.
ifdef BOARD_SEPOLICY_DIRS
BOARD_VENDOR_SEPOLICY_DIRS += $(BOARD_SEPOLICY_DIRS)
endif

###########################################################
# Compute policy files to be used in policy build.
# $(1): files to include
# $(2): directories in which to find files
###########################################################

define build_policy
$(strip $(foreach type, $(1), $(foreach file, $(addsuffix /$(type), $(2)), $(sort $(wildcard $(file))))))
endef

sepolicy_build_files := security_classes \
                        initial_sids \
                        access_vectors \
                        global_macros \
                        neverallow_macros \
                        mls_macros \
                        mls_decl \
                        mls \
                        policy_capabilities \
                        te_macros \
                        attributes \
                        ioctl_defines \
                        ioctl_macros \
                        *.te \
                        roles_decl \
                        roles \
                        users \
                        initial_sid_contexts \
                        fs_use \
                        genfs_contexts \
                        port_contexts

sepolicy_compat_files := $(foreach ver, $(PLATFORM_SEPOLICY_COMPAT_VERSIONS), \
                           $(addprefix compat/$(ver)/, $(addsuffix .cil, $(ver))))

# Security classes and permissions defined outside of system/sepolicy.
security_class_extension_files := $(call build_policy, security_classes access_vectors, \
  $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY) \
  $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY) \
  $(BOARD_VENDOR_SEPOLICY_DIRS) $(BOARD_ODM_SEPOLICY_DIRS))

ifneq (,$(strip $(security_class_extension_files)))
  $(error Only platform SELinux policy may define classes and permissions: $(strip $(security_class_extension_files)))
endif

ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR
  # Checks if there are public system_ext policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(SYSTEM_EXT_PUBLIC_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_SYSTEM_EXT_PUBLIC_SEPOLICY := true
  endif
  # Checks if there are public/private system_ext policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(SYSTEM_EXT_PUBLIC_POLICY) $(SYSTEM_EXT_PRIVATE_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_SYSTEM_EXT_SEPOLICY := true
  endif
endif # ifdef HAS_SYSTEM_EXT_SEPOLICY_DIR

ifdef HAS_PRODUCT_SEPOLICY_DIR
  # Checks if there are public product policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(PRODUCT_PUBLIC_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_PRODUCT_PUBLIC_SEPOLICY := true
  endif
  # Checks if there are public/private product policy files.
  policy_files := $(call build_policy, $(sepolicy_build_files), $(PRODUCT_PUBLIC_POLICY) $(PRODUCT_PRIVATE_POLICY))
  ifneq (,$(strip $(policy_files)))
    HAS_PRODUCT_SEPOLICY := true
  endif
endif # ifdef HAS_PRODUCT_SEPOLICY_DIR

with_asan := false
ifneq (,$(filter address,$(SANITIZE_TARGET)))
  with_asan := true
endif

ifeq ($(PRODUCT_SHIPPING_API_LEVEL),)
  #$(warning no product shipping level defined)
else ifneq ($(call math_lt,29,$(PRODUCT_SHIPPING_API_LEVEL)),)
  ifneq ($(BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW),)
    $(error BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW cannot be set on a device shipping with R or later, and this is tested by CTS.)
  endif
endif

ifeq ($(PRODUCT_SHIPPING_API_LEVEL),)
  #$(warning no product shipping level defined)
else ifneq ($(call math_lt,30,$(PRODUCT_SHIPPING_API_LEVEL)),)
  ifneq ($(BUILD_BROKEN_ENFORCE_SYSPROP_OWNER),)
    $(error BUILD_BROKEN_ENFORCE_SYSPROP_OWNER cannot be set on a device shipping with S or later, and this is tested by CTS.)
  endif
endif

#################################


build_policy :=
sepolicy_build_files :=
with_asan :=
