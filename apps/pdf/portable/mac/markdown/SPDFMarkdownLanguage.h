#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMarkdownLanguage : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* displayName;
@property(nonatomic, readonly, copy) NSArray<NSString*>* aliases;
- (instancetype)initWithIdentifier:(NSString*)identifier
                       displayName:(NSString*)displayName
                           aliases:(NSArray<NSString*>*)aliases NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPDFMarkdownLanguageCatalog : NSObject
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownLanguage*>* languages;
+ (instancetype)sharedCatalog;
- (nullable SPDFMarkdownLanguage*)languageForFenceIdentifier:(nullable NSString*)identifier;
- (NSArray<SPDFMarkdownLanguage*>*)languagesMatchingQuery:(NSString*)query;
@end

@interface SPDFMarkdownLanguagePickerModel : NSObject
@property(nonatomic, readonly) SPDFMarkdownLanguageCatalog* catalog;
@property(nonatomic, copy) NSString* query;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownLanguage*>* filteredLanguages;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, readonly, nullable) SPDFMarkdownLanguage* selectedLanguage;

- (instancetype)initWithCatalog:(SPDFMarkdownLanguageCatalog*)catalog NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (void)moveSelectionBy:(NSInteger)delta;
- (void)moveSelectionByPage:(NSInteger)direction visibleRowCount:(NSUInteger)visibleRowCount;
- (void)selectFirst;
- (void)selectLast;
@end

NS_ASSUME_NONNULL_END
