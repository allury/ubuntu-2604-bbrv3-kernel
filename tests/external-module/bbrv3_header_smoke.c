#include <linux/init.h>
#include <linux/module.h>

static int __init bbrv3_header_smoke_init(void)
{
	return 0;
}

static void __exit bbrv3_header_smoke_exit(void)
{
}

module_init(bbrv3_header_smoke_init);
module_exit(bbrv3_header_smoke_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Compile-only validation for released BBRv3 kernel headers");
