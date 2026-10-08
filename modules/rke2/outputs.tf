output "script" {
  description = "Rendered startup script that was executed on the node."
  value       = local.script
  sensitive   = true
}
