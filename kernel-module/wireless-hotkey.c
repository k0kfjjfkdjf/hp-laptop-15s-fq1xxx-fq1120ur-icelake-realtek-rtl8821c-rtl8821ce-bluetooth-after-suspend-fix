// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *  Airplane mode button for AMD, HP & Xiaomi laptops
 *
 *  Copyright (C) 2014-2017 Alex Hung <alex.hung@canonical.com>
 *  Copyright (C) 2021 Advanced Micro Devices
 *
 *  btfix: based on drivers/platform/x86/wireless-hotkey.c from Linux v7.2.
 *  Added: on resume from suspend/hibernation, re-evaluate _STA of the HP
 *  wireless device (HPQ6001). On HP laptops this ACPI method is what powers
 *  the Wi-Fi and Bluetooth radios on at boot (it drives the radio enable GPIO
 *  pads, e.g. W_DISABLE2#/BT_EN). Some HP BIOSes (e.g. HP Laptop 15s-fq1xxx,
 *  board 86C9, BIOS F.30) never redo this on resume from S3, so the Bluetooth
 *  half of combo cards such as Realtek RTL8821CE stays off and drops off USB.
 *  Calling the BIOS's own method finds and raises the right pin on every
 *  model by itself: no hard-coded GPIO number.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/input.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/acpi.h>
#include <acpi/acpi_bus.h>

MODULE_DESCRIPTION("Airplane mode button for AMD, HP & Xiaomi laptops (+ HP radio re-enable on resume)");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Alex Hung");
MODULE_VERSION("1.0-btfix");
MODULE_ALIAS("acpi*:HPQ6001:*");
MODULE_ALIAS("acpi*:WSTADEF:*");
MODULE_ALIAS("acpi*:AMDI0051:*");
MODULE_ALIAS("acpi*:LGEX0815:*");

static bool resume_fix = true;
module_param(resume_fix, bool, 0644);
MODULE_PARM_DESC(resume_fix,
	"On HP (HPQ6001) re-run the BIOS radio power-on method (_STA) after resume (default: Y)");

struct wl_button {
	struct input_dev *input_dev;
	char phys[32];
};

static const struct acpi_device_id wl_ids[] = {
	{"HPQ6001", 0},
	{"WSTADEF", 0},
	{"AMDI0051", 0},
	{"LGEX0815", 0},
	{"", 0},
};

static bool wl_is_hp(struct acpi_device *adev)
{
	return adev && !strcmp(acpi_device_hid(adev), "HPQ6001");
}

static int wireless_input_setup(struct device *dev)
{
	struct wl_button *button = dev_get_drvdata(dev);
	int err;

	button->input_dev = input_allocate_device();
	if (!button->input_dev)
		return -ENOMEM;

	snprintf(button->phys, sizeof(button->phys), "%s/input0",
		 acpi_device_hid(ACPI_COMPANION(dev)));

	button->input_dev->name = "Wireless hotkeys";
	button->input_dev->phys = button->phys;
	button->input_dev->id.bustype = BUS_HOST;
	button->input_dev->evbit[0] = BIT(EV_KEY);
	set_bit(KEY_RFKILL, button->input_dev->keybit);

	err = input_register_device(button->input_dev);
	if (err)
		goto err_free_dev;

	return 0;

err_free_dev:
	input_free_device(button->input_dev);
	return err;
}

static void wireless_input_destroy(struct device *dev)
{
	struct wl_button *button = dev_get_drvdata(dev);

	input_unregister_device(button->input_dev);
	kfree(button);
}

static void wl_notify(acpi_handle handle, u32 event, void *data)
{
	struct wl_button *button = data;

	if (event != 0x80) {
		pr_info("Received unknown event (0x%x)\n", event);
		return;
	}

	input_report_key(button->input_dev, KEY_RFKILL, 1);
	input_sync(button->input_dev);
	input_report_key(button->input_dev, KEY_RFKILL, 0);
	input_sync(button->input_dev);
}

/*
 * btfix: the HP BIOS powers the radios on in WLBT._STA, which it only runs
 * at boot. Run it again after every resume.
 */
static int wl_resume(struct device *dev)
{
	struct acpi_device *adev = ACPI_COMPANION(dev);
	unsigned long long sta;
	acpi_status status;

	if (!resume_fix || !wl_is_hp(adev))
		return 0;

	status = acpi_evaluate_integer(adev->handle, "_STA", NULL, &sta);
	if (ACPI_FAILURE(status))
		dev_warn(dev, "btfix: _STA on resume failed: %s\n",
			 acpi_format_exception(status));
	else
		dev_info(dev, "btfix: radios re-enabled by BIOS _STA after resume (0x%llx)\n",
			 sta);

	return 0;	/* never block resume */
}

static DEFINE_SIMPLE_DEV_PM_OPS(wl_pm_ops, NULL, wl_resume);

static int wl_probe(struct platform_device *pdev)
{
	struct acpi_device *adev;
	struct wl_button *button;
	int err;

	adev = ACPI_COMPANION(&pdev->dev);
	if (!adev)
		return -ENODEV;

	button = kzalloc(sizeof(*button), GFP_KERNEL);
	if (!button)
		return -ENOMEM;

	platform_set_drvdata(pdev, button);

	err = wireless_input_setup(&pdev->dev);
	if (err) {
		pr_err("Failed to setup wireless hotkeys\n");
		kfree(button);
		return err;
	}
	err = acpi_dev_install_notify_handler(adev, ACPI_DEVICE_NOTIFY,
					      wl_notify, button);
	if (err) {
		pr_err("Failed to install ACPI notify handler\n");
		wireless_input_destroy(&pdev->dev);
		return err;
	}

	if (wl_is_hp(adev))
		dev_info(&pdev->dev, "btfix %s: radio re-enable on resume is %s\n",
			 THIS_MODULE->version ? THIS_MODULE->version : "",
			 resume_fix ? "ON" : "OFF");

	return 0;
}

static void wl_remove(struct platform_device *pdev)
{
	acpi_dev_remove_notify_handler(ACPI_COMPANION(&pdev->dev),
				       ACPI_DEVICE_NOTIFY, wl_notify);
	wireless_input_destroy(&pdev->dev);
}

static struct platform_driver wl_driver = {
	.probe = wl_probe,
	.remove = wl_remove,
	.driver = {
		.name = "wireless-hotkey",
		.acpi_match_table = wl_ids,
		.pm = pm_sleep_ptr(&wl_pm_ops),
	},
};

module_platform_driver(wl_driver);
