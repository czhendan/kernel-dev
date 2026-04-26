/*
 * hello-1.c - The simplest kernel module.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/printk.h> /* Needed for pr_info() */

static int __init my_init(void)
{
    pr_info(KERN_INFO "Hello!\n");
    return 0;
}

static void __exit my_exit(void)
{
    pr_info(KERN_INFO "Goodbye!\n");
}

module_init(my_init);
module_exit(my_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("czd");