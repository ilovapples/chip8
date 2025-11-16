#include <stdlib.h>
#include "../../c/arg_parse/bitset.h"

struct node {
	void *data;
	struct node *link;
};

struct queue {
	struct node *start, *end;
};

struct queue queue_init()
{
	return (struct queue) {
		.start = NULL,
		.end = NULL,
	};
}

void queue_enqueue(struct queue *q, void *data)
{
	struct node *const new_node = malloc(sizeof(struct node));
	new_node->data = data, new_node->link = NULL;
	if (q->end != NULL) q->end->link = new_node;
	else q->start = new_node;
	q->end = new_node;
}

void *queue_dequeue(struct queue *q)
{
	struct node *const start = q->start;
	if (start->link != NULL) {
		q->start = start->link;
	} else {
		q->start = NULL;
		q->end = NULL;
	}
	void *const data = start->data;
	free(start);
	return data;
}
