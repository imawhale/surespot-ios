//
//  HomeDataSource.m
//  surespot
//
//  Created by Adam on 11/2/13.
//  Copyright (c) 2013 surespot. All rights reserved.
//

#import "HomeDataSource.h"
#import "NetworkManager.h"
#import "FileController.h"
#import "CocoaLumberjack.h"
#import "SDWebImageManager.h"
#import "IdentityController.h"
#import "SharedUtils.h"

#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
#else
static const DDLogLevel ddLogLevel = DDLogLevelOff;
#endif


@interface  HomeDataSource()
@property (strong, atomic) NSString * cChat;
@property (strong, atomic) NSString * ourUsername;
@end

@implementation HomeDataSource
-(HomeDataSource*)init: (NSString *) ourUsername {
    self = [super init];
    
    if (self != nil) {
        _ourUsername = ourUsername;
        //if we have data on file, load it
        //otherwise load from network
        NSString * path =[FileController getHomeFilename: ourUsername];
        DDLogVerbose(@"looking for home data at: %@", path);
        id homeData = nil;
        @try {
            homeData = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        }
        @catch (NSException * e) {
            DDLogError(@"error loading home data: %@", e);
        }
        if (homeData) {            
            DDLogVerbose(@"loading home data from: %@", path);
            _latestUserControlId = [[homeData objectForKey:@"userControlId"] integerValue];
            _friends = [homeData objectForKey:@"friends"];
        }
                
        if (!_friends) {
            _friends = [NSMutableArray new];
        }
    }
    
    DDLogVerbose(@"HomeDataSource init ourUsername: %@, latestUserControlId: %ld", _ourUsername, (long)_latestUserControlId);
    return self;
}

-(void) loadFriendsCallback: (void(^)(BOOL success)) callback{
    DDLogInfo(@"loadFriends for %@", _ourUsername);
    NSDictionary* userInfo = @{@"key": @"loadFriends"};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"startProgress" object:self userInfo:userInfo];
    
    [[[NetworkManager sharedInstance] getNetworkController:_ourUsername] getFriendsSuccessBlock:^(NSURLSessionTask *task, id JSON) {
        //DDLogInfo(@"get friends response: %ld",  (long)[task.response statusCode]);
        
        _latestUserControlId = [[JSON objectForKey:@"userControlId"] integerValue];
        
        NSArray * friendDicts = [JSON objectForKey:@"friends"];
        for (NSDictionary * friendDict in friendDicts) {
            Friend * newFriend = [[Friend alloc] initWithDictionary: friendDict ourUsername:_ourUsername];
            if (![_friends containsObject:newFriend]) {
                [_friends addObject: newFriend];
            }
            else {
                DDLogInfo(@"Friend %@ already exists, not adding", newFriend.name);
            }
        };
        [self postRefresh];
        callback(YES);
        DDLogInfo(@"loadFriends for %@ success", _ourUsername);
        NSDictionary* userInfo = @{@"key": @"loadFriends"};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"stopProgress" object:self userInfo:userInfo];
        
        
    } failureBlock:^(NSURLSessionTask *operation,  NSError *Error) {
        DDLogInfo(@"response failure: %@",  Error);
        [self postRefresh];
        callback(NO);
        DDLogInfo(@"loadFriends for %@ failure", _ourUsername);
        NSDictionary* userInfo = @{@"key": @"loadFriends"};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"stopProgress" object:self userInfo:userInfo];
        
    }];
    
}

- (void) setFriend: (NSString *) username  {
    Friend * theFriend = [self getFriendByName:username];
    if (!theFriend) {
        theFriend = [self addFriend:username];
    }
    
    [theFriend setFriend];
    [self postRefresh];
}

- (Friend *) addFriend: (NSString *) name {
    Friend * theFriend = [Friend new];
    theFriend.name =name;
    @synchronized (_friends) {
        [SharedUtils setMute:NO forUsername:_ourUsername friendName: name];
        [_friends addObject:theFriend];
    }
    return theFriend;
}

- (void)addFriendInvited:(NSString *) username
{
    DDLogVerbose(@"entered");
    Friend * theFriend = [self getFriendByName:username];
    if (!theFriend) {
        theFriend = [self addFriend:username];
        
    }
    
    [theFriend setInvited:YES];
    [self postRefresh];
}

- (void)addFriendInviter:(NSString *) username
{
    DDLogVerbose(@"entered");
    Friend * theFriend = [self getFriendByName:username];
    
    if (!theFriend) {
        theFriend = [self addFriend:username];
    }
    
    [theFriend setInviter:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"invite" object:theFriend];
    });
    [self postRefresh];
    
}

- (void) removeFriend: (Friend *) afriend withRefresh: (BOOL) refresh {
    DDLogInfo(@"name: %@", afriend.name);
    @synchronized (_friends) {
        [_friends removeObject:afriend];
        [SharedUtils setMute:NO forUsername:_ourUsername friendName:[afriend name]];
    }
    if (refresh) {
        [self postRefresh];
    }
}

-(void) postRefreshSave: (BOOL) save {
    [self sort];
    if (save) {
        [self writeToDisk];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"refreshHome" object:nil];
    });
}

-(void) postRefresh {
    [self postRefreshSave:YES];
}

-(Friend *) getFriendByName: (NSString *) name {
    @synchronized (_friends) {
        for (Friend * afriend in _friends) {
            if ([[afriend name] isEqualToString:name]) {
                return  afriend;
            }
        }
    }
    
    return nil;
}

-(void) setAvailableMessageId: (NSInteger) availableId forFriendname: (NSString *) friendname suppressNew: (BOOL) suppressNew {
    Friend * afriend = [self getFriendByName:friendname];
    if (afriend) {
        afriend.availableMessageId = availableId;
        if (suppressNew) {
            afriend.lastReceivedMessageId = availableId;
        }
        if (afriend.availableMessageId > afriend.lastReceivedMessageId) {
            afriend.hasNewMessages = YES;
        }
    }
}

-(void) setAvailableMessageControlId: (NSInteger) availableId forFriendname: (NSString *) friendname {
    Friend * afriend = [self getFriendByName:friendname];
    if (afriend) {
        afriend.availableMessageControlId = availableId;
    }
}

-(void) writeToDisk {
    @synchronized (_friends) {
        if (_latestUserControlId > 0 || _friends.count > 0) {
            NSString * filename = [FileController getHomeFilename: _ourUsername];
            DDLogVerbose(@"saving home data to disk at %@, latestUserControlId: %ld, currentChat: %@",filename, (long)_latestUserControlId, [self getCurrentChat]);
            NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
            if (_friends.count > 0) {
                [dict setObject:_friends  forKey:@"friends"];
            }
            if (_latestUserControlId > 0) {
                [dict setObject:[NSNumber numberWithInteger: _latestUserControlId] forKey:@"userControlId"];
            }
            if ([self getCurrentChat]) {
                [dict setObject:[self getCurrentChat] forKey:@"currentChat"];
            }
            BOOL saved =[NSKeyedArchiver archiveRootObject:dict toFile:filename];
            DDLogVerbose(@"save success?: %@",saved ? @"YES" : @"NO");
        }
    }
}

-(void) setCurrentChat: (NSString *) username {
    @synchronized (self) {
        if (username) {
            Friend * afriend = [self getFriendByName:username];
            [afriend setChatActive:YES];
            afriend.lastReceivedMessageId = afriend.availableMessageId;
            afriend.hasNewMessages = NO;
            [self postRefresh];
        }
        
        DDLogInfo(@"setCurrentChat: %@", username);
        self.cChat = username;
        [SharedUtils setCurrentTab:username];
    }
}

-(NSString *) getCurrentChat {
    
    NSString * theCurrentChat;
    @synchronized (self) {
        theCurrentChat = _cChat;
    }
    
    DDLogInfo(@"currentChat: %@", theCurrentChat);
    return theCurrentChat;
    
}

-(void) sort {
    @synchronized (_friends) {
        DDLogInfo(@"sorting friends");
        _friends = [NSMutableArray  arrayWithArray:[_friends sortedArrayUsingSelector:@selector(compare:)]];
    }
}

-(BOOL) hasAnyNewMessages {
    @synchronized (_friends) {
        
        for (Friend * afriend in _friends) {
            if (afriend.hasNewMessages ) {
                return YES;
            }
        }
    }
    
    return NO;
    
    
}

-(void) setFriendImageUrl: (NSString *) url forFriendname: (NSString *) name version: (NSString *) version iv: (NSString *) iv hashed: (BOOL) hashed {
    Friend * afriend = [self getFriendByName:name];
    if (afriend) {
        NSString * oldUrl = [afriend imageUrl];
        if (oldUrl) {
            [[[SDWebImageManager sharedManager] imageCache] removeImageForKey:oldUrl fromDisk:YES];
        }
        
        [afriend setImageUrl:url];
        [afriend setImageVersion:version];
        [afriend setImageIv:iv];
        [afriend setImageHashed:hashed];
        
        [self postRefresh];
    }
}

-(void) setFriendAlias: (NSString *) alias data: (NSString *) data  friendname: (NSString *) friendname version: (NSString *) version iv: (NSString *) iv hashed: (BOOL) hashed {
    Friend * afriend = [self getFriendByName:friendname];
    if (afriend) {
        [afriend setAliasData:data];
        [afriend setAliasVersion:version];
        [afriend setAliasIv:iv];
        [afriend setAliasHashed:hashed];
        
        //assign plain
        if (alias) {
            [afriend setAliasPlain: alias];
            [SharedUtils setAlias:alias forUsername:_ourUsername friendName:friendname];
        }
        else {
            [afriend decryptAlias];
        }
        
        [self postRefresh];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"reloadSwipeView" object: nil];
    }
}

-(void) removeFriendAlias: (NSString *) friendname {
    Friend * afriend = [self getFriendByName:friendname];
    if (afriend) {
        [afriend setAliasData:nil];
        [afriend setAliasVersion:nil];
        [afriend setAliasIv:nil];
        
        [afriend setAliasPlain: nil];
        [SharedUtils removeAliasForUsername:_ourUsername friendName:friendname];
        
        [self postRefresh];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"reloadSwipeView" object: nil];
    }
}

-(void) removeFriendImage: (NSString *) friendname {
    Friend * afriend = [self getFriendByName:friendname];
    if (afriend) {
        NSString * oldUrl = [afriend imageUrl];
        if (oldUrl) {
            [[[SDWebImageManager sharedManager] imageCache] removeImageForKey:oldUrl fromDisk:YES];
        }
        
        [afriend setImageUrl:nil];
        [afriend setImageVersion:nil];
        [afriend setImageIv:nil];
        
        [self postRefresh];
    }
}

-(void) closeAllChats {
    @synchronized(_friends) {
        for (Friend * f : _friends) {
            [f setChatActive:NO];
        }
    }
}

- (void)muteFriendName:(NSString *) friendname
{
    DDLogVerbose(@"mute friend");
    Friend * theFriend = [self getFriendByName:friendname];
    if (theFriend) {
        [theFriend setMuted:YES];
        [SharedUtils setMute:YES forUsername:_ourUsername friendName:friendname];
        [self postRefresh];
    }
}

- (void)unmuteFriendName:(NSString *) friendname
{
    DDLogVerbose(@"unmute friend");
    Friend * theFriend = [self getFriendByName:friendname];
    if (theFriend) {
        [theFriend setMuted:NO];
        [SharedUtils setMute:NO forUsername:_ourUsername friendName:friendname];
        [self postRefresh];
    }
}

@end
