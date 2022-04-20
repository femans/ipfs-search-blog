---
layout: single
title:  "# NSFW-filter for ipfs-search.com"
excerpt: When we upgraded the frontend for IPFS-search, it became immediately apparent that there was a lot of X-rated material on ipfs, and this made the browsing experience less than pleasant at times.
header :
 teaser: "/assets/images/ditribution.jpg"
 overlay_image: "/assets/images/ditribution.jpg"
 overlay_filter: rgba(0, 0, 0, 0.7)
tags:
  - NSFW-filter
  - Frontend
  
---
## The problem

When we upgraded the frontend for IPFS-search, and while doing so made the graphic content a lot more visible, it became immediately apparent that there was a lot of X-rated material on ipfs, and this made the browsing experience less than pleasant at times. Most search queries turned up at least some imagery of explicit scenes;

![It happened on a boat last tuesday](Blog%20NSFW-%20f70ee/Untitled.png)

It happened on a boat last tuesday

![They are white, and in they are in a house. What else do you need to know?](Blog%20NSFW-%20f70ee/Untitled%201.png)

They are white, and they are in a house. What else do you need to know?

![Fresh ideas on where to get vegetables and what to do with them](Blog%20NSFW-%20f70ee/Untitled%202.png)

Fresh ideas on where to get vegetables and what to do with them

![Clearly, the girls on the right are captivated by the scene in the middle. ](Blog%20NSFW-%20f70ee/Untitled%203.png)

Clearly, the girls on the right are captivated by the scene in the middle. 

## To the rescue: NSFW.js

Filtering this out is not a trivial matter. In order to do this properly, you need to classify all content automatically, and for this you need an intelligent system. Fortunately, we found [NSFW.js](http://nsfwjs.com), an open source library that implements an already trained AI model to classify images on nudity and pornographic content and should also work for drawings. The library claims to have 93% accuracy. We made it a priority to integrate this into the search engine.

The AI looks at an image and responds with an estimate classification for five categories: ‘porn’, ‘sexy’, ‘hentai’ (sexually explicit drawings), ‘drawing’ (non-explicit), and ‘neutral’. The estimate comes as a number between 0 and 1, with 1 being absolute certainty that it falls in this category and 0 being absolute certainty that it doesn’t. 

## Architecture

For the architecture, we decided on making a [microservice](https://github.com/ipfs-search/nsfw-server) to classify IPFS images. The first idea was to cache the results on IPFS, but after some trial and error it seemed that the benefit did not outweigh the trouble, and we decided to work in stead with a simple server-side cache. While the NSFW.js library is targeted for client-side classification, it was relatively simple to integrate it into a node/express server, with a Nginx reverse proxy with a built-in cache. 

The rationale for using a microservice, rather than simply frontend-based, was that this would be able to serve both the search frontend and the search crawlers and/or API; where the crawlers in due time would be able to attach metadata about the classification to the database, the frontend would directly be able to access this information as long as it isn’t (yet) available, and decide on whether/how to display the results from the API. 

## Prototype

For the first iteration, the prototype, we did nothing more than to blur out images in the frontend (using CSS) if they would be classified as “not suitable for work”. A simple toggle-switch, with its setting stored in the browsers’ local storage, would turn the feature on and off. The search frontend would call for each individual image the microservice, and as long as the result was undecided, (either because the request was in-flight or because it returned an error), ‘assume the worst’, i.e., keep the image blurred. We implemented a tooltip message displaying the classification percentages for images in the browser, so we could see what data the assessment was based on.

![Without blur filter (but pixelated for editorial reasons)](Blog%20NSFW-%20f70ee/Untitled%204.png)

Without blur filter (but pixelated for editorial reasons)

![With blur filter enabled.](Blog%20NSFW-%20f70ee/Untitled%205.png)

With blur filter enabled.

The reason for doing this on the frontend and not yet in the crawler was to field-test the microservice without committing this information to the database, by being able to see directly which images it blurred and which it didn’t. 

The result was already much friendlier search-engine with a lot less obnoxious feel to it. It turned out that the estimation thresholds for the categories ‘sexy’, ‘porn’ and ‘hentai’ need to be very low, around 10-15%, or it started to miss a lot of hits. As would be expected, there were some false positives, and the lower the threshold would be set, the more there are. A few false negatives occur too, but not that many. 

![False positive: Obama eating a strawberry classifies as porn with a certainty of 45%. Maybe it is that look on his face](Blog%20NSFW-%20f70ee/Untitled%206.png)

False positive: Obama eating a strawberry classifies as porn with a certainty of 45%. Maybe it is that look on his face

![False positive: This guy, unabashedly exhibiting his banana; 24% certain it is pornography. (It seems that the classifier has a thing for fruit.)](Blog%20NSFW-%20f70ee/Untitled%207.png)

False positive: This guy, unabashedly exhibiting his banana; 24% certain it is pornography. (It seems that the classifier has a thing for fruit.)

![False positive: These golden lines classify 45% as porn. No comment. They aren’t even that curvy.](Blog%20NSFW-%20f70ee/Untitled%208.png)

False positive: These golden lines classify 45% as porn. No comment. They aren’t even that curvy

![False negative: Only 8% certain of pornographic content, which doesn’t meet our (current) threshold. Warning: the image contains product placement](Blog%20NSFW-%20f70ee/Untitled%209.png)

False negative: Only 8% certain of pornographic content, which doesn’t meet our (current) threshold. Warning: the image contains product placement

![False negative: the classifier is probably thrown off by the letters photoshopped as background layer; it is not a drawing, and it is definitely not neutral](Blog%20NSFW-%20f70ee/Untitled%2010.png)

False negative: the classifier is probably thrown off by the letters photoshopped as background layer; it is not a drawing, and it is definitely not neutral

![False negative; the internet/IPFS is overflowing with this kind of imaginative artwork. Fortunately, most of it is properly classified by NSFW.js as ‘hentai’, because these cartoons are not for kids.](Blog%20NSFW-%20f70ee/Untitled%2011.png)

False negative; the internet/IPFS is overflowing with this kind of imaginative artwork. Fortunately, most of it is properly classified by NSFW.js as ‘hentai’, because these cartoons are not for kids

Altogether, the NSFW-filter prototype worked very well, and because of this, we brought the prototype to production, just so we had a UX we could show with some more confidence to people in general. 

## Backend integration

The obvious downsides of having this done solely by the frontend are:

- you can not add an adult-filter to the search API, and simply not showing the results that surpass the threshold causes weird paging issues (e.g., if all results of a single page have positive NSFW classification, you would see an empty page). The best we could come up with was blurring it, but typically, you don’t want these results at all.
- Because IPFS is still pretty slow, the first time classification for new content can take long; after this, the cache takes care of it.

So, the second phase was to make the code a bit more mature, and incorporate a connection with the microservice into the backend, the crawler. We did this by adding the classifications of files to the metadata of the search engine database. Then the API could filter on it by request. 

To do this, we needed to add one more feature: information about which exact AI model had been used for a specific classification. NSFW.js has several models directly available, and it can not be ruled out that other, better ones will become available in the future, or even that we would be training our own datasets e.g. using user feedback. 
So, stored data should have a reference to which model was used to generate it, in the way that some next generation API can make informed decisions about, for example, whether to access the microservice for newer data or not. We solved this by calculating the IPFS-CID of the model files (using [js-ipfs](https://github.com/ipfs/js-ipfs/tree/master/docs)) and adding this to the classification-microservices’ output. 

Finally, we integrated the microservice API into the crawler and added a nsfw filter on the frontend for the search query. 

## Considerations and debate

It is currently unknown to us how the 93% accuracy has been calculated, but with any AI based classification, you will always get a number of false positives and negatives. We considered using user feedback for improving the model, but quickly abandoned this because of all the complications this would bring. There are GDPR regulations, storage of feedback data, fighting trolls and bots and trollbots, design of UX for feedback, security, QA, and so forth. But most of all was there the already tough issue of keeping websearch neutral, unbiased and completely private while at the same time having to curate users’ opinions about sensitive, highly debatable matters. 

Because the debate does not end with filtering nudity, it merely starts there. What about targeted violence, fake-news, controversial symbols or politics, discrimination, etc. etc.? What about written documents or audiorecordings, shouldn’t these be filtered? With the resources we have now, this is too much to be dealing with, and it may not be urgent, yet. However, with an increasing user base and search-index covering more and more materials, these questions are likely to come up down the line. A good set of solutions solution to deal with this will obviously be much more complex than implementing an open source library into the system. 

## Bonus bonus!

As the nsfw filter classifies for drawings too, we can use it to create a query parameter filter for that too, without much effort.  

## Conclusion

We were successful to deal with the issue of content that is ‘not suitable for work’ in a straightforward way without the need for too many resources, thanks to the plugin [NSFW.js](https://nsfwjs.com/). The user experience of [IPFS-search.com](http://IPFS-search.com) has increased a lot as a consequence.

## References

1. Microservice repo - https://github.com/ipfs-search/nsfw-server
2. NSFW.js - [https://nsfwjs.com/](https://nsfwjs.com/)
3. [ipfs-search.com](https://ipfs-search.com/)
