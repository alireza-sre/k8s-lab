# aws-node-termination-handler (queue mode) consumes this queue and cordons +
# drains a node before EC2 or Auto Scaling takes it away. Every ASG in the
# cluster (control plane and pools) has a terminate lifecycle hook, so
# instance refreshes, scale-ins and AZ rebalancing all wait for the drain.
resource "aws_sqs_queue" "node_termination" {
  name                      = "${var.cluster_name}-node-termination"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "node_termination_queue" {
  statement {
    sid       = "EventBridgeAndSqs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.node_termination.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.node_termination.arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "node_termination" {
  queue_url = aws_sqs_queue.node_termination.id
  policy    = data.aws_iam_policy_document.node_termination_queue.json
}

locals {
  termination_event_patterns = {
    asg-lifecycle = {
      source        = ["aws.autoscaling"]
      "detail-type" = ["EC2 Instance-terminate Lifecycle Action"]
      detail        = { AutoScalingGroupName = [{ prefix = "${var.cluster_name}-" }] }
    }
    spot-interruption = {
      source        = ["aws.ec2"]
      "detail-type" = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source        = ["aws.ec2"]
      "detail-type" = ["EC2 Instance Rebalance Recommendation"]
    }
    state-change = {
      source        = ["aws.ec2"]
      "detail-type" = ["EC2 Instance State-change Notification"]
    }
    scheduled-change = {
      source        = ["aws.health"]
      "detail-type" = ["AWS Health Event"]
      detail = {
        service           = ["EC2"]
        eventTypeCategory = ["scheduledChange"]
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "node_termination" {
  for_each      = local.termination_event_patterns
  name          = "${var.cluster_name}-nth-${each.key}"
  event_pattern = jsonencode(each.value)
}

resource "aws_cloudwatch_event_target" "node_termination" {
  for_each = local.termination_event_patterns
  rule     = aws_cloudwatch_event_rule.node_termination[each.key].name
  arn      = aws_sqs_queue.node_termination.arn
}
